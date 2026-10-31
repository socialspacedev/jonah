import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var lib = Library()
    @State private var search = ""
    @State private var selection: Set<PodTrack.ID> = []
    @AppStorage("hideExported") private var hideExported = false
    @State private var showDuplicates = false
    @State private var confirmDelete = false
    @State private var dropTargeted = false
    @State private var sortOrder = [
        KeyPathComparator(\PodTrack.artist),
        KeyPathComparator(\PodTrack.album),
        KeyPathComparator(\PodTrack.discNumber),
        KeyPathComparator(\PodTrack.trackNumber),
    ]

    private var shown: [PodTrack] {
        let q = search.trimmingCharacters(in: .whitespaces)
        func keep(_ t: PodTrack) -> Bool {
            if hideExported && lib.exported.contains(t.location) { return false }
            return q.isEmpty || [t.title, t.artist, t.album, t.genre].contains { $0.localizedCaseInsensitiveContains(q) }
        }
        // Duplicates stay together, best copy first, rather than following the column sort.
        if showDuplicates {
            return Library.duplicateGroups(lib.tracks)
                .filter { $0.contains(where: keep) }
                .sorted { ($0[0].artist, $0[0].title) < ($1[0].artist, $1[0].title) }
                .flatMap { $0 }
        }
        return lib.tracks.filter(keep).sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            switch lib.state {
            case .noDevice: placeholder(nil)
            case .failed(let message): placeholder(message)
            case .loading: ProgressView("Reading songs…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded: songTable
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .navigationTitle(lib.state == .loaded ? lib.deviceName : "Jonah")
        .navigationSubtitle(lib.state == .loaded ? "\(lib.tracks.count) songs" : "")
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
                    Button("Eject", systemImage: "eject", action: lib.eject)
                        .help("Eject the iPod")
                        .disabled(lib.progress != nil)
                }
            }
        }
    }

    // MARK: Songs

    private var songTable: some View {
        let rows = shown
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { t in
                Toggle("", isOn: checkBinding(t.id)).labelsHidden().disabled(!t.exists)
            }
            .width(22)
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
        }
        .searchable(text: $search, prompt: "Title, artist or album")
        .onKeyPress(.space) {
            toggle(selection)
            return .handled
        }
        .contextMenu(forSelectionType: PodTrack.ID.self) { ids in
            Button("Tick") { lib.checked.formUnion(ids) }
            Button("Untick") { lib.checked.subtract(ids) }
        } primaryAction: { ids in
            toggle(ids)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard lib.canEdit, lib.progress == nil else { return false }
            lib.add(urls)
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
            Button("Delete", role: .destructive, action: lib.deleteChecked)
        } message: {
            Text("Jonah backs up the song list first, but the song files are removed from the iPod for good. Export any you want to keep before deleting.")
        }
    }

    private func footer(_ rows: [PodTrack]) -> some View {
        let picked = lib.checkedTracks
        let bytes = picked.reduce(Int64(0)) { $0 + $1.size }
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                Toggle("Hide exported", isOn: $hideExported).toggleStyle(.checkbox)
                Toggle("Duplicates only", isOn: $showDuplicates).toggleStyle(.checkbox)
                if showDuplicates {
                    Button("Tick Lesser Copies", action: lib.tickLesserDuplicates)
                        .help("Ticks every copy except the highest-bitrate one in each group")
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

    private func checkBinding(_ id: PodTrack.ID) -> Binding<Bool> {
        Binding(
            get: { lib.checked.contains(id) },
            set: { if $0 { lib.checked.insert(id) } else { lib.checked.remove(id) } }
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
