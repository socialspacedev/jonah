import AppKit
import AVFoundation
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

    var exportProgress: Double?
    var exportResult: ExportResult?

    var deviceName: String { root?.lastPathComponent ?? "" }
    var checkedTracks: [PodTrack] { tracks.filter { checked.contains($0.id) } }

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lookForIPod() }
            }
        }
        lookForIPod()
    }

    /// Picks the first mounted volume with an iPod_Control folder. Leaves a manually
    /// opened folder alone unless it has gone away.
    func lookForIPod() {
        if let root, FileManager.default.fileExists(atPath: root.path), state != .noDevice { return }
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

    static func isIPod(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("iPod_Control").path)
    }

    func open(_ url: URL) {
        guard Self.isIPod(url) else {
            state = .failed(PodError.notAnIPod.localizedDescription)
            return
        }
        root = url
        state = .loading
        checked = []
        exportResult = nil
        Task {
            let (tracks, fallback) = await Self.load(url)
            self.tracks = tracks
            self.usedFallback = fallback
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
            let asset = AVURLAsset(url: url)
            let meta = (try? await asset.load(.commonMetadata)) ?? []
            func tag(_ id: AVMetadataIdentifier) async -> String {
                guard let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id).first else { return "" }
                return (try? await item.load(.stringValue)) ?? ""
            }
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            let title = await tag(.commonIdentifierTitle)
            tracks.append(PodTrack(
                id: i,
                title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
                artist: await tag(.commonIdentifierArtist),
                album: await tag(.commonIdentifierAlbumName),
                genre: "",
                trackNumber: 0,
                discNumber: 0,
                year: 0,
                duration: duration.isFinite ? duration : 0,
                size: Int64((try? url.resourceValues(forKeys: Set(keys)).fileSize) ?? 0),
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
        var folder: URL
    }

    func exportChecked(to folder: URL) {
        let songs = checkedTracks
        exportProgress = 0
        exportResult = nil
        Task {
            let result = await Self.export(songs, to: folder) { done in
                Task { @MainActor in self.exportProgress = Double(done) / Double(max(songs.count, 1)) }
            }
            self.exportProgress = nil
            self.exportResult = result
        }
    }

    /// Copies each song to folder/Artist/Album/"NN Title.ext". Never overwrites —
    /// a clash gets " 2", " 3"… appended.
    nonisolated static func export(_ songs: [PodTrack], to folder: URL, progress: @escaping @Sendable (Int) -> Void) async -> ExportResult {
        await Task.detached {
            let fm = FileManager.default
            var copied = 0
            var failed: [String] = []
            for (i, song) in songs.enumerated() {
                let dir = folder
                    .appendingPathComponent(safe(song.artist, or: "Unknown Artist"))
                    .appendingPathComponent(safe(song.album, or: "Unknown Album"))
                let number = song.trackNumber > 0 ? String(format: "%02d ", song.trackNumber) : ""
                let ext = song.fileURL.pathExtension.lowercased()
                let base = number + safe(song.title, or: "Untitled")
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
                } catch {
                    failed.append(song.title)
                }
                progress(i + 1)
            }
            return ExportResult(copied: copied, failed: failed, folder: folder)
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
        try? NSWorkspace.shared.unmountAndEjectDevice(at: root)
    }
}
