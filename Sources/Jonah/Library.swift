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
    var playlists: [PodPlaylist] = []
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
            playlists = []
            checked = []
            state = .noDevice
        }
    }

    nonisolated static func isIPod(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("iPod_Control").path)
    }

    /// `quietly` keeps the current list on screen while re-reading, for after an edit.
    func open(_ url: URL, keepTicks: Bool = false, quietly: Bool = false) {
        guard Self.isIPod(url) else {
            state = .failed(PodError.notAnIPod.localizedDescription)
            return
        }
        root = url
        if !quietly { state = .loading }
        if !keepTicks { checked = [] }
        editProblem = "Loading…"
        exported = ExportLog.load(for: url)
        Task {
            let (tracks, fallback) = await Self.load(url)
            let playlists = fallback ? [] : await Task.detached { Self.loadPlaylists(url) }.value
            let problem = await Task.detached { Self.editProblem(url, fallback: fallback) }.value
            self.tracks = tracks
            self.playlists = playlists
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

    nonisolated static func loadPlaylists(_ root: URL) -> [PodPlaylist] {
        guard let data = try? Data(contentsOf: databaseURL(root)), let tree = try? DBTree.parse([UInt8](data)) else { return [] }
        return DBTree.readPlaylists(tree)
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

    /// Adds files to the iPod, and to `playlist` too if given.
    func add(_ urls: [URL], into playlist: UInt64? = nil) {
        let files = Self.audioFiles(in: urls)
        guard !files.isEmpty else {
            notice = Notice(text: "No audio files found in what was added.", warning: true)
            return
        }
        edit(delete: [], add: files, into: playlist)
    }

    func deleteChecked() {
        edit(delete: checked, add: [])
    }

    func editPlaylist(_ change: DBTree.PlaylistEdit) {
        edit(delete: [], add: [], playlists: [change])
    }

    /// Adds songs to the end of a playlist, skipping any already in it.
    func addSongs(_ ids: [PodTrack.ID], to playlist: PodPlaylist) {
        let new = ids.filter { !playlist.trackIDs.contains($0) }
        guard !new.isEmpty else { return }
        editPlaylist(.setTracks(playlist.id, playlist.trackIDs + new))
    }

    private func edit(delete ids: Set<PodTrack.ID>, add files: [URL], into playlist: UInt64? = nil,
                      playlists changes: [DBTree.PlaylistEdit] = []) {
        guard let root, canEdit, progress == nil else { return }
        progress = 0
        progressLabel = !files.isEmpty ? "Adding…" : !ids.isEmpty ? "Deleting…" : "Updating playlists…"
        notice = nil
        Task {
            do {
                let result = try await Self.applyEdits(delete: ids, add: files, into: playlist, playlists: changes,
                                                       to: root) { label, value in
                    Task { @MainActor in
                        self.progressLabel = label
                        self.progress = value
                    }
                }
                ExportLog.remove(result.removedLocations, for: root)
                MeasureLog.remove(result.removedLocations, for: root)
                MeasureLog.add(result.measured, for: root)
                self.exported.subtract(result.removedLocations)
                self.checked.subtract(ids)
                self.progress = nil
                var parts: [String] = []
                if result.added > 0 { parts.append("Added \(result.added) song\(result.added == 1 ? "" : "s").") }
                if result.deleted > 0 { parts.append("Deleted \(result.deleted) song\(result.deleted == 1 ? "" : "s").") }
                if !result.skipped.isEmpty { parts.append("Skipped \(result.skipped.count): \(result.skipped.prefix(3).joined(separator: "; "))") }
                if !result.leftOver.isEmpty {
                    parts.append("\(result.leftOver.count) file\(result.leftOver.count == 1 ? "" : "s") couldn't be removed from the iPod and still take\(result.leftOver.count == 1 ? "s" : "") up space: \(result.leftOver.prefix(3).joined(separator: ", ")).")
                }
                let warn = !result.skipped.isEmpty || !result.leftOver.isEmpty
                if result.added == 0 && result.deleted == 0 {
                    // Only playlists changed: no need to re-read every song.
                    self.playlists = Self.loadPlaylists(root)
                    self.notice = warn ? Notice(text: parts.joined(separator: " "), warning: true) : nil
                    return
                }
                self.notice = Notice(text: parts.isEmpty ? "Nothing changed." : parts.joined(separator: " "), warning: warn)
                let note = self.notice
                self.open(root, keepTicks: true, quietly: true)
                self.notice = note
            } catch {
                self.progress = nil
                self.notice = Notice(text: error.localizedDescription, warning: true)
            }
        }
    }

    /// Levels and trims every song that needs it; see `improvePlayback(on:progress:)`.
    func improvePlayback() {
        guard let root, canEdit, progress == nil else { return }
        progress = 0
        progressLabel = "Listening…"
        notice = nil
        Task {
            do {
                let result = try await Task.detached {
                    try await Self.improvePlayback(on: root) { label, value in
                        Task { @MainActor in
                            self.progressLabel = label
                            self.progress = value
                        }
                    }
                }.value
                self.progress = nil
                var parts = [result.trimmed == 0 && result.levelled == 0 ? "Every song was already done."
                             : "Trimmed silence from \(result.trimmed) song\(result.trimmed == 1 ? "" : "s"), levelled \(result.levelled)."]
                if result.levelled > 0 { parts.append("Turn on Sound Check in the iPod's Settings to hear the levelling.") }
                if result.unreadable > 0 {
                    parts.append("\(result.unreadable) couldn't be read, perhaps copy-protected.")
                }
                self.notice = Notice(text: parts.joined(separator: " "), warning: result.unreadable > 0)
            } catch {
                self.progress = nil
                self.notice = Notice(text: error.localizedDescription, warning: true)
            }
        }
    }

    func removeTrims() {
        guard let root, canEdit, progress == nil else { return }
        do {
            let removed = try Self.removeTrims(on: root)
            notice = Notice(text: removed == 0 ? "No songs had Jonah's trims." :
                                "Removed Jonah's trims from \(removed) song\(removed == 1 ? "" : "s"). They play in full again.")
        } catch {
            notice = Notice(text: error.localizedDescription, warning: true)
        }
    }

    func restore(_ backup: URL) {
        guard let root, progress == nil else { return }
        do {
            try Self.restore(backup, to: root)
            open(root, keepTicks: true, quietly: true)
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

    /// Ejects off the main thread: macOS asks the unmount approval callback above,
    /// which runs on the main thread, and waiting here would leave it unanswered
    /// until macOS gave up (about 10 s), sometimes refusing the eject.
    func eject() {
        guard let root, !ejecting else { return }
        ejecting = true
        Task {
            let error = await Task.detached { () -> String? in
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: root); return nil } catch { return error.localizedDescription }
            }.value
            ejecting = false
            if let error { notice = Notice(text: "Couldn't eject: \(error)", warning: true) }
        }
    }
}
