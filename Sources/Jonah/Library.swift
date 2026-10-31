import AppKit
import AVFoundation
import DiskArbitration
import Observation

/// Finds a mounted iPod, loads its songs, and copies chosen ones off it.
@MainActor @Observable
final class Library {
    enum State: Equatable {
        case noDevice
        case loading
        case loaded
        case failed(String)
    }

    var state: State = .noDevice
    var root: URL?
    var tracks: [PodTrack] = []
    var checked: Set<PodTrack.ID> = []
    /// True when the database was unreadable and we fell back to reading tags from the files.
    var usedFallback = false

    /// Why this iPod can't be changed (nil means adding and deleting are allowed).
    var editProblem: String? = "Loading…"
    var canEdit: Bool { editProblem == nil && state == .loaded }
    /// Locations of songs already exported from this iPod.
    var exported: Set<String> = []

    var progress: Double?
    var progressLabel = ""
    var notice: Notice?

    struct Notice: Equatable {
        var text: String
        var warning = false
        var folder: URL?
    }

    /// Keeps macOS's device-sync agent (AMPDeviceDiscoveryAgent) from ejecting the
    /// iPod moments after it mounts — it doesn't support these old models and lets go
    /// of them, leaving the iPod showing "OK to disconnect" mid-read.
    private var diskSession: DASession?
    private var ejecting = false

    var deviceName: String { root?.lastPathComponent ?? "" }
    var checkedTracks: [PodTrack] { tracks.filter { checked.contains($0.id) } }

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lookForIPod() }
            }
        }
        holdIPodsMounted()
        lookForIPod()
    }

    /// Dissents from any unmount of a volume with an iPod_Control folder while Jonah
    /// is open, except via our own Eject button. Finder's eject will say Jonah is
    /// using it, which is true.
    private func holdIPodsMounted() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        DASessionSetDispatchQueue(session, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskUnmountApprovalCallback(session, nil, { disk, context in
            guard let context,
                  let info = DADiskCopyDescription(disk) as? [CFString: Any],
                  let volume = info[kDADiskDescriptionVolumePathKey] as? URL,
                  Library.isIPod(volume) else { return nil }
            let lib = Unmanaged<Library>.fromOpaque(context).takeUnretainedValue()
            let allow = MainActor.assumeIsolated { lib.ejecting }
            if allow { return nil }
            let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnBusy),
                                              "Jonah is using this iPod. Use Jonah's Eject button, or quit Jonah." as CFString)
            return Unmanaged.passRetained(dissenter)
        }, context)
        diskSession = session
    }

    /// Picks the first mounted volume with an iPod_Control folder. Leaves a manually
    /// opened folder alone unless it has gone away.
    func lookForIPod() {
        if let root, FileManager.default.fileExists(atPath: root.path), state != .noDevice { return }
        rescan()
    }

    /// Re-reads from scratch — a drive that dropped out mid-read leaves songs wrongly
    /// marked missing until this runs.
    func rescan() {
        if let root, Self.isIPod(root) {
            open(root, keepTicks: true)
            return
        }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        if let pod = volumes.first(where: Self.isIPod) {
            open(pod)
        } else {
            root = nil
            tracks = []
            checked = []
            state = .noDevice
        }
    }

    nonisolated static func isIPod(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("iPod_Control").path)
    }

    func open(_ url: URL, keepTicks: Bool = false) {
        guard Self.isIPod(url) else {
            state = .failed(PodError.notAnIPod.localizedDescription)
            return
        }
        root = url
        state = .loading
        if !keepTicks { checked = [] }
        editProblem = "Loading…"
        exported = ExportLog.load(for: url)
        Task {
            let (tracks, fallback) = await Self.load(url)
            let problem = await Task.detached { Self.editProblem(url, fallback: fallback) }.value
            self.tracks = tracks
            self.checked.formIntersection(tracks.filter(\.exists).map(\.id))
            self.usedFallback = fallback
            self.editProblem = problem
            self.state = tracks.isEmpty ? .failed("No songs found on \(url.lastPathComponent).") : .loaded
        }
    }

    nonisolated static func load(_ root: URL) async -> ([PodTrack], Bool) {
        let db = root.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
        if let data = try? Data(contentsOf: db),
           let tracks = try? ITunesDB.parse(data, root: root),
           tracks.contains(where: \.exists) {
            return (tracks, false)
        }
        return (await scanFiles(root), true)
    }

    /// Fallback for a missing or corrupt database: read tags straight from the audio files.
    nonisolated static func scanFiles(_ root: URL) async -> [PodTrack] {
        let music = ITunesDB.resolve(["iPod_Control", "Music"], under: root)
        let audio: Set<String> = ["mp3", "m4a", "m4p", "m4b", "aac", "wav", "aif", "aiff"]
        let keys: [URLResourceKey] = [.fileSizeKey]
        let files = (FileManager.default.enumerator(at: music, includingPropertiesForKeys: keys)?.allObjects as? [URL] ?? [])
            .filter { audio.contains($0.pathExtension.lowercased()) }

        var tracks: [PodTrack] = []
        for (i, url) in files.enumerated() {
            let tags = await AudioTags.read(url)
            let rel = url.path.dropFirst(root.path.count).split(separator: "/").joined(separator: ":")
            tracks.append(PodTrack(
                id: i,
                title: tags.title.isEmpty ? url.deletingPathExtension().lastPathComponent : tags.title,
                artist: tags.artist,
                album: tags.album,
                genre: tags.genre,
                trackNumber: tags.trackNumber,
                discNumber: 0,
                year: tags.year,
                duration: tags.duration,
                bitrate: tags.bitrate,
                size: Int64((try? url.resourceValues(forKeys: Set(keys)).fileSize) ?? 0),
                location: ":" + rel,
                fileURL: url,
                exists: true
            ))
        }
        return tracks
    }

    // MARK: Export

    struct ExportResult: Equatable {
        var copied: Int
        var failed: [String]
        var copiedLocations: [String]
        var folder: URL
    }

    func exportChecked(to folder: URL, inFolders: Bool = true) {
        guard let root else { return }
        let songs = checkedTracks
        progress = 0
        progressLabel = "Copying…"
        notice = nil
        Task {
            let result = await Self.export(songs, to: folder, inFolders: inFolders) { done in
                Task { @MainActor in self.progress = Double(done) / Double(max(songs.count, 1)) }
            }
            ExportLog.add(result.copiedLocations, for: root)
            self.exported.formUnion(result.copiedLocations)
            self.progress = nil
            let copied = "Copied \(result.copied) song\(result.copied == 1 ? "" : "s")."
            self.notice = Notice(text: result.failed.isEmpty ? copied : "\(copied) \(result.failed.count) couldn't be read.",
                                 warning: !result.failed.isEmpty, folder: folder)
        }
    }

    // MARK: Changing the iPod

    func add(_ urls: [URL]) {
        let files = Self.audioFiles(in: urls)
        guard !files.isEmpty else {
            notice = Notice(text: "No audio files found in what was added.", warning: true)
            return
        }
        edit(delete: [], add: files)
    }

    func deleteChecked() {
        edit(delete: checked, add: [])
    }

    private func edit(delete ids: Set<PodTrack.ID>, add files: [URL]) {
        guard let root, canEdit, progress == nil else { return }
        progress = 0
        progressLabel = ids.isEmpty ? "Adding…" : "Deleting…"
        notice = nil
        Task {
            do {
                let result = try await Self.applyEdits(delete: ids, add: files, to: root) { label, value in
                    Task { @MainActor in
                        self.progressLabel = label
                        self.progress = value
                    }
                }
                ExportLog.remove(result.removedLocations, for: root)
                self.exported.subtract(result.removedLocations)
                self.checked.subtract(ids)
                self.progress = nil
                var parts: [String] = []
                if result.added > 0 { parts.append("Added \(result.added) song\(result.added == 1 ? "" : "s").") }
                if result.deleted > 0 { parts.append("Deleted \(result.deleted) song\(result.deleted == 1 ? "" : "s").") }
                if !result.skipped.isEmpty { parts.append("Skipped \(result.skipped.count): \(result.skipped.prefix(3).joined(separator: "; "))") }
                self.notice = Notice(text: parts.isEmpty ? "Nothing changed." : parts.joined(separator: " "),
                                     warning: !result.skipped.isEmpty)
                let note = self.notice
                self.open(root, keepTicks: true)
                self.notice = note
            } catch {
                self.progress = nil
                self.notice = Notice(text: error.localizedDescription, warning: true)
            }
        }
    }

    func restore(_ backup: URL) {
        guard let root, progress == nil else { return }
        do {
            try Self.restore(backup, to: root)
            open(root, keepTicks: true)
            notice = Notice(text: "Song list restored from \(backup.lastPathComponent).")
        } catch {
            notice = Notice(text: "Couldn't restore: \(error.localizedDescription)", warning: true)
        }
    }

    /// Ticks every copy except the best one in each duplicate group.
    func tickLesserDuplicates() {
        for group in Self.duplicateGroups(tracks) { checked.formUnion(group.dropFirst().map(\.id)) }
    }

    /// Copies each song to folder/Artist/Album/"NN Title.ext", or with inFolders off,
    /// straight into folder as "Artist - Title.ext". Never overwrites — a clash gets
    /// " 2", " 3"… appended.
    nonisolated static func export(_ songs: [PodTrack], to folder: URL, inFolders: Bool = true, progress: @escaping @Sendable (Int) -> Void) async -> ExportResult {
        await Task.detached {
            let fm = FileManager.default
            var copied = 0
            var failed: [String] = []
            var locations: [String] = []
            for (i, song) in songs.enumerated() {
                let dir = inFolders ? folder
                    .appendingPathComponent(safe(song.artist, or: "Unknown Artist"))
                    .appendingPathComponent(safe(song.album, or: "Unknown Album")) : folder
                let prefix = !inFolders ? (song.artist.isEmpty ? "" : safe(song.artist, or: "") + " - ")
                    : song.trackNumber > 0 ? String(format: "%02d ", song.trackNumber) : ""
                let ext = song.fileURL.pathExtension.lowercased()
                let base = prefix + safe(song.title, or: "Untitled")
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    var dest = dir.appendingPathComponent(base).appendingPathExtension(ext)
                    var n = 2
                    while fm.fileExists(atPath: dest.path) {
                        dest = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
                        n += 1
                    }
                    try fm.copyItem(at: song.fileURL, to: dest)
                    copied += 1
                    locations.append(song.location)
                } catch {
                    failed.append(song.title)
                }
                progress(i + 1)
            }
            return ExportResult(copied: copied, failed: failed, copiedLocations: locations, folder: folder)
        }.value
    }

    nonisolated static func safe(_ name: String, or fallback: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if s.isEmpty { return fallback }
        return String(s.prefix(120))
    }

    func eject() {
        guard let root else { return }
        ejecting = true
        defer { ejecting = false }
        try? NSWorkspace.shared.unmountAndEjectDevice(at: root)
    }
}
