import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    enum Source: Hashable {
        case songs
        case playlist(UInt64)
    }

    /// A playlist being named: a new one (with these songs) or an existing one.
    struct Naming {
        var playlist: PodPlaylist?
        var tracks: [PodTrack.ID] = []
    }

    @State private var lib = Library()
    @State private var preview = Preview()
    @State private var source: Source? = .songs
    @State private var search = ""
    @State private var selection: Set<PodTrack.ID> = []
    /// The last checkbox clicked, for shift-click ticking a range.
    @State private var lastTicked: PodTrack.ID?
    @AppStorage("hideExported") private var hideExported = false
    @State private var showDuplicates = false
    @State private var confirmDelete = false
    @State private var confirmPlayback = false
    @State private var dropTargeted = false
    @State private var sortOrder = [
        KeyPathComparator(\PodTrack.artist),
        KeyPathComparator(\PodTrack.album),
        KeyPathComparator(\PodTrack.discNumber),
        KeyPathComparator(\PodTrack.trackNumber),
    ]
    /// Empty means playlist order.
    @State private var playlistSort: [KeyPathComparator<PodTrack>] = []
    @State private var naming: Naming?
    @State private var nameText = ""
    @State private var deletingPlaylist: PodPlaylist?

    private var playlist: PodPlaylist? {
        guard case .playlist(let id) = source else { return nil }
        return lib.playlists.first { $0.id == id }
    }

    private var canEditPlaylist: Bool {
        guard let playlist else { return false }
        return !playlist.smart && lib.canEdit && lib.progress == nil
    }

    /// Dragging rows reorders the playlist, so only while it's shown in its own order.
    private var canReorder: Bool { canEditPlaylist && playlistSort.isEmpty && !showDuplicates }

    private var shown: [PodTrack] {
        let q = search.trimmingCharacters(in: .whitespaces)
        func keep(_ t: PodTrack) -> Bool {
            if hideExported && lib.exported.contains(t.location) { return false }
            return q.isEmpty || [t.title, t.artist, t.album, t.genre].contains { $0.localizedCaseInsensitiveContains(q) }
        }
        var base = lib.tracks
        if let playlist {
            let byID = Dictionary(lib.tracks.map { ($0.id, $0) }) { a, _ in a }
            base = Self.order(of: playlist).compactMap { byID[$0] }
        }
        // Duplicates stay together, best copy first, rather than following the column sort.
        if showDuplicates {
            return Library.duplicateGroups(base)
                .filter { $0.contains(where: keep) }
                .sorted { ($0[0].artist, $0[0].title) < ($1[0].artist, $1[0].title) }
                .flatMap { $0 }
        }
        if playlist != nil {
            return playlistSort.isEmpty ? base.filter(keep) : base.filter(keep).sorted(using: playlistSort)
        }
        return base.filter(keep).sorted(using: sortOrder)
    }

    /// A playlist's songs in order, each listed once.
    private static func order(of playlist: PodPlaylist) -> [PodTrack.ID] {
        var seen = Set<PodTrack.ID>()
        return playlist.trackIDs.filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 300)
        } detail: {
            detail
        }
        .frame(minWidth: 880, minHeight: 440)
        .onChange(of: lib.root) {
            preview.stop()
            source = .songs
        }
        .onChange(of: source) {
            if source == nil { source = .songs }
            playlistSort = []
        }
        .alert(naming?.playlist == nil ? "New Playlist" : "Rename Playlist",
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }),
               presenting: naming) { n in
            TextField("Name", text: $nameText)
            Button("Cancel", role: .cancel) {}
            Button(n.playlist == nil ? "Create" : "Rename") { finishNaming(n) }
        } message: { n in
            if n.playlist == nil && !n.tracks.isEmpty {
                Text("With the \(n.tracks.count) selected song\(n.tracks.count == 1 ? "" : "s").")
            }
        }
        .confirmationDialog("Delete the playlist “\(deletingPlaylist?.name ?? "")”?",
                            isPresented: Binding(get: { deletingPlaylist != nil }, set: { if !$0 { deletingPlaylist = nil } }),
                            presenting: deletingPlaylist) { p in
            Button("Delete Playlist", role: .destructive) {
                if source == .playlist(p.id) { source = .songs }
                lib.editPlaylist(.delete(p.id))
            }
        } message: { _ in
            Text("Its songs stay on the iPod.")
        }
        .confirmationDialog("Level and trim songs?", isPresented: $confirmPlayback) {
            Button("Level & Trim") { lib.improvePlayback() }
        } message: {
            Text("Jonah listens to every song it hasn't before, which takes a while the first time, then skips silence at the start and end of each and gives songs without one a Sound Check level. Start and stop times or levels already set in iTunes are kept. Songs added from now on are done as they're added.")
        }
    }

    private var detail: some View {
        Group {
            switch lib.state {
            case .noDevice: placeholder(nil)
            case .failed(let message): placeholder(message)
            case .loading: ProgressView("Reading songs…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded: songTable
            }
        }
        .navigationTitle(lib.state == .loaded ? playlist?.name ?? lib.deviceName : "Jonah")
        .navigationSubtitle(lib.state != .loaded ? "" : playlist.map { "\(Self.order(of: $0).count) songs on \(lib.deviceName)" }
                            ?? "\(lib.tracks.count) songs")
        .toolbar {
            ToolbarItemGroup {
                Button("Reload", systemImage: "arrow.clockwise", action: lib.rescan)
                    .help("Read the iPod again")
                    .keyboardShortcut("r")
                    .disabled(lib.state == .loading || lib.progress != nil)
                Button("Add Songs…", systemImage: "plus", action: chooseSongsToAdd)
                    .help(lib.canEdit ? "Add songs to the iPod (or drag files onto the list)" : lib.editProblem ?? "")
                    .disabled(!lib.canEdit || lib.progress != nil)
                Button("Open Folder…", systemImage: "folder", action: chooseFolder)
                    .help("Open an iPod (or a copy of one) from a folder")
                Menu("Playback", systemImage: "waveform") {
                    Button("Level & Trim Songs…") { confirmPlayback = true }
                    Button("Remove Jonah's Trims", action: lib.removeTrims)
                }
                .help(lib.canEdit ? "Even out volume and skip silence at the start and end of songs" : lib.editProblem ?? "")
                .disabled(!lib.canEdit || lib.progress != nil)
                Menu("Backups", systemImage: "clock.arrow.circlepath") {
                    Button("Show Backups in Finder") {
                        try? FileManager.default.createDirectory(at: Library.backupsFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Library.backupsFolder)
                    }
                    Button("Restore Song List from Backup…", action: chooseBackup)
                        .disabled(lib.root == nil || lib.usedFallback || lib.progress != nil)
                }
                .help("Jonah backs up the iPod's song list before every change")
                if lib.root != nil {
                    Button("Eject", systemImage: "eject") {
                        preview.stop()
                        lib.eject()
                    }
                        .help("Eject the iPod")
                        .disabled(lib.progress != nil)
                }
            }
        }
    }

    // MARK: Playlists

    private var sidebar: some View {
        List(selection: $source) {
            Label("Songs", systemImage: "music.note").tag(Source.songs)
            if !lib.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(lib.playlists) { p in
                        Label(p.name, systemImage: p.smart ? "gearshape" : "music.note.list")
                            .tag(Source.playlist(p.id))
                            .help(p.smart ? "Smart playlist: iTunes chose its songs by rules, so they can't be changed here" : "")
                            .dropDestination(for: String.self) { items, _ in
                                guard lib.canEdit, lib.progress == nil, !p.smart else { return false }
                                lib.addSongs(Self.songIDs(items), to: p)
                                return true
                            }
                            .contextMenu {
                                Button("Rename…") { startNaming(p) }
                                Button("Delete Playlist…") { deletingPlaylist = p }
                            }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("New Playlist", systemImage: "plus") { startNaming(nil) }
                    .buttonStyle(.borderless)
                    .disabled(!lib.canEdit || lib.progress != nil)
                    .help(lib.canEdit ? "Make a new playlist (or drag songs onto one to add them)" : lib.editProblem ?? "")
                Spacer()
            }
            .padding(10)
        }
    }

    private func startNaming(_ playlist: PodPlaylist?, tracks: [PodTrack.ID] = []) {
        guard lib.canEdit, lib.progress == nil else { return }
        nameText = playlist?.name ?? ""
        naming = Naming(playlist: playlist, tracks: tracks)
    }

    private func finishNaming(_ n: Naming) {
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let p = n.playlist {
            lib.editPlaylist(.rename(p.id, to: name))
        } else {
            let id = UInt64.random(in: 1...UInt64.max)
            lib.editPlaylist(.create(id: id, name: name, tracks: n.tracks))
            source = .playlist(id)
        }
    }

    private func removeFromPlaylist(_ ids: Set<PodTrack.ID>) {
        guard canEditPlaylist, let playlist, !ids.isEmpty else { return }
        lib.editPlaylist(.setTracks(playlist.id, Self.order(of: playlist).filter { !ids.contains($0) }))
    }

    /// Dropped rows go before the row at `index` in the list shown.
    private func move(_ ids: [PodTrack.ID], to index: Int, in rows: [PodTrack]) {
        guard canReorder, let playlist else { return }
        let moving = Set(ids)
        var order = Self.order(of: playlist)
        guard !moving.isEmpty, moving.isSubset(of: order) else { return }
        let before = index < rows.count ? rows[index...].first { !moving.contains($0.id) }?.id : nil
        let moved = order.filter(moving.contains)
        order.removeAll(where: moving.contains)
        order.insert(contentsOf: moved, at: before.flatMap { order.firstIndex(of: $0) } ?? order.count)
        if order != Self.order(of: playlist) { lib.editPlaylist(.setTracks(playlist.id, order)) }
    }

    /// Songs are dragged as "jonah-song:<id>" text.
    private static func dragToken(_ id: PodTrack.ID) -> String { "jonah-song:\(id)" }

    private static func songIDs(_ items: [String]) -> [PodTrack.ID] {
        items.compactMap { $0.hasPrefix("jonah-song:") ? Int($0.dropFirst("jonah-song:".count)) : nil }
    }

    // MARK: Songs

    private var songTable: some View {
        let rows = shown
        return Table(of: PodTrack.self, selection: $selection, sortOrder: playlist == nil ? $sortOrder : $playlistSort) {
            TableColumn("") { t in
                Toggle("", isOn: checkBinding(t.id, rows)).labelsHidden().disabled(!t.exists)
            }
            .width(22)
            TableColumn("") { t in
                Button { preview.toggle(t) } label: {
                    Image(systemName: preview.isPlaying(t) ? "pause.fill" : "play.fill")
                        .foregroundStyle(preview.track?.id == t.id ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!t.exists)
                .help("Play (P)")
            }
            .width(16)
            TableColumn("") { t in
                if lib.exported.contains(t.location) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary).help("Already exported")
                }
            }
            .width(16)
            TableColumn("Title", value: \.title) { t in
                Text(t.title).foregroundStyle(t.exists ? .primary : .tertiary)
            }
            TableColumn("Artist", value: \.artist)
            TableColumn("Album", value: \.album)
            TableColumn("#", value: \.trackNumber) { t in
                Text(t.trackNumber > 0 ? "\(t.trackNumber)" : "").monospacedDigit()
            }
            .width(32)
            TableColumn("Time", value: \.duration) { t in
                Text(Duration.seconds(t.duration).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
            }
            .width(52)
            TableColumn("Bitrate", value: \.bitrate) { t in
                Text(t.bitrate > 0 ? "\(t.bitrate) kbps" : "").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(64)
            TableColumn("Kind", value: \.kind).width(44)
        } rows: {
            if canReorder {
                ForEach(rows) { t in TableRow(t).draggable(Self.dragToken(t.id)) }
                    .dropDestination(for: String.self) { index, items in move(Self.songIDs(items), to: index, in: rows) }
            } else {
                ForEach(rows) { t in TableRow(t).draggable(Self.dragToken(t.id)) }
            }
        }
        .searchable(text: $search, prompt: "Title, artist or album")
        .onKeyPress(.space) {
            toggle(selection)
            return .handled
        }
        .onKeyPress("p") {
            if let t = rows.first(where: { selection.contains($0.id) && $0.exists }) {
                preview.toggle(t)
            } else if let t = preview.track {
                preview.toggle(t)
            }
            return .handled
        }
        .onDeleteCommand { removeFromPlaylist(selection) }
        .contextMenu(forSelectionType: PodTrack.ID.self) { ids in
            let picked = rows.filter { ids.contains($0.id) }
            if picked.count == 1, let t = picked.first, t.exists {
                Button(preview.isPlaying(t) ? "Pause" : "Play") { preview.toggle(t) }
                Divider()
            }
            if !picked.isEmpty {
                Button("Tick") { lib.checked.formUnion(picked.filter(\.exists).map(\.id)) }
                Button("Untick") { lib.checked.subtract(ids) }
            }
            if !picked.isEmpty && lib.canEdit && lib.progress == nil {
                Divider()
                Menu("Add to Playlist") {
                    ForEach(lib.playlists.filter { !$0.smart }) { p in
                        Button(p.name) { lib.addSongs(picked.map(\.id), to: p) }
                    }
                    if lib.playlists.contains(where: { !$0.smart }) { Divider() }
                    Button("New Playlist…") { startNaming(nil, tracks: picked.map(\.id)) }
                }
                if canEditPlaylist {
                    Button("Remove from Playlist") { removeFromPlaylist(ids) }
                }
            }
        } primaryAction: { ids in
            toggle(ids)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard lib.canEdit, lib.progress == nil else { return false }
            lib.add(urls, into: canEditPlaylist ? playlist?.id : nil)
            return true
        } isTargeted: { dropTargeted = $0 && lib.canEdit }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(4)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer(rows) }
        .confirmationDialog("Delete \(lib.checked.count) song\(lib.checked.count == 1 ? "" : "s") from the iPod?",
                            isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let t = preview.track, lib.checked.contains(t.id) { preview.stop() }
                lib.deleteChecked()
            }
        } message: {
            Text("Jonah backs up the song list first, but the song files are removed from the iPod for good. Export any you want to keep before deleting.")
        }
    }

    private func footer(_ rows: [PodTrack]) -> some View {
        let picked = lib.checkedTracks
        let bytes = picked.reduce(Int64(0)) { $0 + $1.size }
        return VStack(spacing: 0) {
            Divider()
            if let t = preview.track { player(t) }
            HStack(spacing: 14) {
                Toggle("Hide exported", isOn: $hideExported).toggleStyle(.checkbox)
                Toggle("Duplicates only", isOn: $showDuplicates).toggleStyle(.checkbox)
                if showDuplicates {
                    Button("Tick Lesser Copies", action: lib.tickLesserDuplicates)
                        .help("Ticks every copy except the highest-bitrate one in each group")
                }
                if playlist != nil && !playlistSort.isEmpty {
                    Button("Back to Playlist Order") { playlistSort = [] }
                        .help("Show the playlist in its own order, so songs can be dragged up and down")
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            HStack(spacing: 12) {
                if let progress = lib.progress {
                    ProgressView(value: progress).frame(width: 160)
                    Text(lib.progressLabel).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else if let notice = lib.notice {
                    Text(notice.text).foregroundStyle(notice.warning ? Color.orange : Color.secondary)
                        .lineLimit(2).textSelection(.enabled)
                    if let folder = notice.folder {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                            .buttonStyle(.link)
                    }
                } else if lib.usedFallback {
                    Text("Database unreadable — songs listed from the files themselves.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(picked.isEmpty ? "Tick songs to export or delete" :
                        "\(picked.count) ticked · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Menu("Tick") {
                    Button("Tick All Shown") { lib.checked.formUnion(rows.filter(\.exists).map(\.id)) }
                    Button("Untick All Shown") { lib.checked.subtract(rows.map(\.id)) }
                    Divider()
                    Button("Untick Everything") { lib.checked.removeAll() }
                    Divider()
                    Button("Tick Lesser Duplicate Copies", action: lib.tickLesserDuplicates)
                }
                .fixedSize()
                if canEditPlaylist {
                    Button("Remove from Playlist") { removeFromPlaylist(selection) }
                        .help("Take the selected songs out of this playlist. They stay on the iPod.")
                        .disabled(selection.isEmpty)
                }
                Button("Delete…", role: .destructive) { confirmDelete = true }
                    .help(lib.canEdit ? "Delete the ticked songs from the iPod" : lib.editProblem ?? "")
                    .disabled(picked.isEmpty || !lib.canEdit || lib.progress != nil)
                Button("Export…", action: chooseDestination)
                    .buttonStyle(.borderedProminent)
                    .disabled(picked.isEmpty || lib.progress != nil)
                    .keyboardShortcut("e")
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .background(.bar)
    }

    private func player(_ t: PodTrack) -> some View {
        let time = { (s: Double) in Duration.seconds(s).formatted(.time(pattern: .minuteSecond)) }
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { preview.toggle(t) } label: {
                    Image(systemName: preview.playing ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(preview.playing ? "Pause" : "Play")
                (Text(t.title) + Text(t.artist.isEmpty ? "" : " — \(t.artist)").foregroundColor(.secondary))
                    .lineLimit(1)
                    .frame(maxWidth: 280, alignment: .leading)
                Slider(value: Binding(get: { preview.position }, set: { preview.seek(to: $0) }),
                       in: 0...max(t.duration, 1))
                    .controlSize(.small)
                Text("\(time(preview.position)) / \(time(t.duration))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button { preview.stop() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Stop")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            Divider()
        }
    }

    /// Shift-click ticks or unticks every song between this checkbox and the last one clicked.
    private func checkBinding(_ id: PodTrack.ID, _ rows: [PodTrack]) -> Binding<Bool> {
        Binding(
            get: { lib.checked.contains(id) },
            set: { on in
                var ids: Set<PodTrack.ID> = [id]
                if NSEvent.modifierFlags.contains(.shift), let anchor = lastTicked,
                   let a = rows.firstIndex(where: { $0.id == anchor }), let b = rows.firstIndex(where: { $0.id == id }) {
                    ids = Set(rows[min(a, b)...max(a, b)].filter(\.exists).map(\.id))
                }
                if on { lib.checked.formUnion(ids) } else { lib.checked.subtract(ids) }
                lastTicked = id
            }
        )
    }

    /// Space / double-click: tick the rows if any are unticked, otherwise untick them.
    private func toggle(_ ids: Set<PodTrack.ID>) {
        let playable = Set(lib.tracks.filter { ids.contains($0.id) && $0.exists }.map(\.id))
        if playable.isSubset(of: lib.checked) { lib.checked.subtract(playable) } else { lib.checked.formUnion(playable) }
    }

    // MARK: Empty state

    private func placeholder(_ message: String?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "ipod")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.tertiary)
            Text(message ?? "Plug in your iPod")
                .font(.title3)
            Text("It should appear in Finder like a USB drive. If it doesn't, put it in disk mode: hold Menu + Play/Pause until the Apple logo, then straight away hold Previous + Next until “Do not disconnect” shows.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            HStack {
                Button("Look Again", action: lib.lookForIPod)
                Button("Open Folder…", action: chooseFolder)
            }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Panels

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the iPod (the folder that contains iPod_Control)"
        if panel.runModal() == .OK, let url = panel.url { lib.open(url) }
    }

    private func chooseSongsToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.prompt = "Add to iPod"
        panel.message = "Choose songs or folders. Formats the iPod can't play are converted to AAC."
        if panel.runModal() == .OK { lib.add(panel.urls) }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Restore"
        panel.message = "Choose a backup folder. The iPod's current song list is backed up first."
        panel.directoryURL = Library.backupsFolder
        if panel.runModal() == .OK, let url = panel.url { lib.restore(url) }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to copy the ticked songs"
        let inFolders = NSButton(checkboxWithTitle: "Sort into Artist / Album folders", target: nil, action: nil)
        inFolders.state = UserDefaults.standard.object(forKey: "exportInFolders") as? Bool == false ? .off : .on
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 36))
        inFolders.frame.origin = NSPoint(x: 12, y: 9)
        inFolders.sizeToFit()
        accessory.addSubview(inFolders)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        panel.directoryURL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(inFolders.state == .on, forKey: "exportInFolders")
        lib.exportChecked(to: url, inFolders: inFolders.state == .on)
    }
}
