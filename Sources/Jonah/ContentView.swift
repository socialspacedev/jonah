import SwiftUI

struct ContentView: View {
    @State private var lib = Library()
    @State private var search = ""
    @State private var selection: Set<PodTrack.ID> = []
    @State private var sortOrder = [
        KeyPathComparator(\PodTrack.artist),
        KeyPathComparator(\PodTrack.album),
        KeyPathComparator(\PodTrack.discNumber),
        KeyPathComparator(\PodTrack.trackNumber),
    ]

    private var shown: [PodTrack] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let hits = q.isEmpty ? lib.tracks : lib.tracks.filter {
            [$0.title, $0.artist, $0.album, $0.genre].contains { $0.localizedCaseInsensitiveContains(q) }
        }
        return hits.sorted(using: sortOrder)
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
                    .disabled(lib.state == .loading || lib.exportProgress != nil)
                Button("Open Folder…", systemImage: "folder", action: chooseFolder)
                    .help("Open an iPod (or a copy of one) from a folder")
                if lib.root != nil {
                    Button("Eject", systemImage: "eject", action: lib.eject)
                        .help("Eject the iPod")
                        .disabled(lib.exportProgress != nil)
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
        .safeAreaInset(edge: .bottom, spacing: 0) { footer(rows) }
    }

    private func footer(_ rows: [PodTrack]) -> some View {
        let picked = lib.checkedTracks
        let bytes = picked.reduce(Int64(0)) { $0 + $1.size }
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if let progress = lib.exportProgress {
                    ProgressView(value: progress).frame(width: 180)
                    Text("Copying…").foregroundStyle(.secondary)
                } else if let result = lib.exportResult {
                    Text(summary(result)).foregroundStyle(result.failed.isEmpty ? Color.secondary : Color.orange)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.folder]) }
                        .buttonStyle(.link)
                } else if lib.usedFallback {
                    Text("Database unreadable — songs listed from the files themselves.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(picked.isEmpty ? "Tick songs to export" :
                        "\(picked.count) ticked · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Menu("Tick") {
                    Button("Tick All Shown") { lib.checked.formUnion(rows.filter(\.exists).map(\.id)) }
                    Button("Untick All Shown") { lib.checked.subtract(rows.map(\.id)) }
                    Divider()
                    Button("Untick Everything") { lib.checked.removeAll() }
                }
                .fixedSize()
                Button("Export…", action: chooseDestination)
                    .buttonStyle(.borderedProminent)
                    .disabled(picked.isEmpty || lib.exportProgress != nil)
                    .keyboardShortcut("e")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func summary(_ r: Library.ExportResult) -> String {
        let copied = "Copied \(r.copied) song\(r.copied == 1 ? "" : "s")."
        return r.failed.isEmpty ? copied : "\(copied) \(r.failed.count) couldn't be read."
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

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Songs will be copied into Artist / Album folders"
        panel.directoryURL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url { lib.exportChecked(to: url) }
    }
}
