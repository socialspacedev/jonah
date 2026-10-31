import AVFoundation
import Foundation

/// Adding and deleting songs on the iPod. Every change goes the same way:
/// back up the database to the Mac, edit it in memory, write it beside the old one,
/// read it back to check, then swap it in. Song files are deleted only after the
/// new database is in place, so a failure part-way never leaves songs without files.
extension Library {
    struct EditSummary: Sendable {
        var added = 0
        var deleted = 0
        var skipped: [String] = []
        var removedLocations: [String] = []
        var backup: URL?
    }

    /// Played as they are by a 3G (Apple Lossless .m4a needs firmware 2.2 or later).
    nonisolated static let nativeFormats: Set<String> = ["mp3", "m4a", "m4b", "m4p", "wav", "aif", "aiff"]
    /// Picked up when a folder is added; anything not native is converted to AAC.
    nonisolated static let audioExtensions: Set<String> =
        nativeFormats.union(["flac", "aac", "caf", "ogg", "oga", "opus", "mp2", "mp4", "aifc"])

    nonisolated static func databaseURL(_ root: URL) -> URL {
        ITunesDB.resolve(["iPod_Control", "iTunes", "iTunesDB"], under: root)
    }

    nonisolated static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Jonah")
    }

    nonisolated static var backupsFolder: URL { supportFolder.appendingPathComponent("Backups") }

    /// Nil when Jonah can safely change this iPod, otherwise why not.
    nonisolated static func editProblem(_ root: URL, fallback: Bool) -> String? {
        if fallback { return "The iPod's song database couldn't be read, so Jonah won't change this iPod. Exporting still works." }
        guard let data = try? Data(contentsOf: databaseURL(root)) else { return "The song database couldn't be read." }
        let bytes = [UInt8](data)
        guard let tree = try? DBTree.parse(bytes), DBTree.serialise(tree) == bytes,
              DBTree.trackList(tree) != nil, DBTree.masterPlaylist(tree) != nil else {
            return "This iPod's database has a layout Jonah can't rewrite safely, so adding and deleting are off. Exporting still works."
        }
        return nil
    }

    /// Expands folders into the audio files inside them.
    nonisolated static func audioFiles(in urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
            if !isDir.boolValue { return [url] }
            let all = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
                .allObjects as? [URL] ?? []
            return all.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    nonisolated static func applyEdits(delete ids: Set<Int>, add files: [URL], to root: URL,
                                       progress: @escaping @Sendable (String, Double) -> Void) async throws -> EditSummary {
        let fm = FileManager.default
        let dbURL = databaseURL(root)
        let original = [UInt8](try Data(contentsOf: dbURL))
        let tree = try DBTree.parse(original)
        guard DBTree.serialise(tree) == original else {
            throw PodError.cantEdit("This iPod's database has a layout Jonah can't rewrite safely.")
        }

        var summary = EditSummary()
        summary.backup = try backUp(root)
        summary.removedLocations = DBTree.remove(ids, from: tree)
        summary.deleted = summary.removedLocations.count

        let music = ITunesDB.resolve(["iPod_Control", "Music"], under: root)
        var copied: [URL] = []   // new files on the iPod, taken off again if anything fails
        do {
            for (i, file) in files.enumerated() {
                progress("Adding \(file.lastPathComponent)", Double(i) / Double(max(files.count, 1)))
                var tags = await AudioTags.read(file)
                guard tags.playable else {
                    summary.skipped.append("\(file.lastPathComponent): not audio Jonah can read")
                    continue
                }
                var source = file
                var ext = file.pathExtension.lowercased()
                var temp: URL?
                if !nativeFormats.contains(ext) {
                    guard let aac = await convertToAAC(file, tags: tags) else {
                        summary.skipped.append("\(file.lastPathComponent): couldn't be converted")
                        continue
                    }
                    let converted = await AudioTags.read(aac)
                    (source, ext, temp) = (aac, "m4a", aac)
                    (tags.bitrate, tags.sampleRate, tags.duration) = (converted.bitrate, converted.sampleRate, converted.duration)
                }
                defer { if let temp { try? fm.removeItem(at: temp) } }

                let (dest, location) = try newHome(in: music, root: root, ext: ext)
                try fm.copyItem(at: source, to: dest)
                copied.append(dest)
                let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                DBTree.add(.init(
                    title: tags.title.isEmpty ? file.deletingPathExtension().lastPathComponent : tags.title,
                    artist: tags.artist, album: tags.album, genre: tags.genre,
                    location: location, ext: ext,
                    trackNumber: tags.trackNumber, year: tags.year, bitrate: tags.bitrate,
                    sampleRate: tags.sampleRate, size: size, durationMs: Int(tags.duration * 1000)
                ), to: tree)
                summary.added += 1
            }

            guard summary.added > 0 || summary.deleted > 0 else { return summary }
            progress("Updating the iPod's song list", 1)
            try replaceDatabase(at: dbURL, with: DBTree.serialise(tree))
        } catch {
            for url in copied { try? fm.removeItem(at: url) }
            throw error
        }

        if summary.deleted > 0 {
            // Both index into the old track order, which no longer holds. Backed up above.
            let itunes = dbURL.deletingLastPathComponent()
            for name in ["Play Counts", "OTGPlaylistInfo"] { try? fm.removeItem(at: itunes.appendingPathComponent(name)) }
            for location in summary.removedLocations {
                try? fm.removeItem(at: ITunesDB.resolve(location.split(separator: ":").map(String.init), under: root))
            }
        }
        return summary
    }

    /// Copies the database and the files that index into it to
    /// ~/Library/Application Support/Jonah/Backups/<iPod> <date>/.
    nonisolated static func backUp(_ root: URL) throws -> URL {
        let fm = FileManager.default
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HHmmss"
        let stamp = format.string(from: Date())
        var dest = backupsFolder.appendingPathComponent("\(root.lastPathComponent) \(stamp)")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = backupsFolder.appendingPathComponent("\(root.lastPathComponent) \(stamp) \(n)")
            n += 1
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let itunes = databaseURL(root).deletingLastPathComponent()
        for name in ["iTunesDB", "Play Counts", "OTGPlaylistInfo"] {
            let file = ITunesDB.resolve([name], under: itunes)
            if fm.fileExists(atPath: file.path) { try fm.copyItem(at: file, to: dest.appendingPathComponent(name)) }
        }
        return dest
    }

    /// Puts a backed-up database back. The current one is backed up first.
    nonisolated static func restore(_ backup: URL, to root: URL) throws {
        let bytes = [UInt8](try Data(contentsOf: backup.appendingPathComponent("iTunesDB")))
        _ = try DBTree.parse(bytes)
        _ = try backUp(root)
        try replaceDatabase(at: databaseURL(root), with: bytes)
        let itunes = databaseURL(root).deletingLastPathComponent()
        for name in ["Play Counts", "OTGPlaylistInfo"] {
            let saved = backup.appendingPathComponent(name)
            let live = itunes.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: live)
            if FileManager.default.fileExists(atPath: saved.path) { try? FileManager.default.copyItem(at: saved, to: live) }
        }
    }

    /// Writes beside the live file, flushes, reads it back to check, then renames over.
    nonisolated private static func replaceDatabase(at url: URL, with bytes: [UInt8]) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent("iTunesDB.jonah-new")
        try? FileManager.default.removeItem(at: temp)
        guard FileManager.default.createFile(atPath: temp.path, contents: Data(bytes)) else {
            throw PodError.cantEdit("Couldn't write to the iPod. Is it locked or full?")
        }
        let handle = try FileHandle(forUpdating: temp)
        try handle.synchronize()
        try handle.close()
        let check = [UInt8](try Data(contentsOf: temp))
        guard check == bytes, (try? DBTree.parse(check)) != nil else {
            try? FileManager.default.removeItem(at: temp)
            throw PodError.cantEdit("The new song list didn't read back correctly, so the iPod was left as it was.")
        }
        guard rename(temp.path, url.path) == 0 else {
            throw PodError.cantEdit("Couldn't swap in the new song list (error \(errno)). The iPod was left as it was.")
        }
    }

    /// A random four-letter name in the emptiest Fxx folder, as iTunes does.
    nonisolated private static func newHome(in music: URL, root: URL, ext: String) throws -> (URL, String) {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(atPath: music.path)) ?? [])
            .filter { $0.count == 3 && $0.uppercased().hasPrefix("F") && Int($0.dropFirst()) != nil }
        let folder = folders.min {
            ((try? fm.contentsOfDirectory(atPath: music.appendingPathComponent($0).path))?.count ?? 0)
                < ((try? fm.contentsOfDirectory(atPath: music.appendingPathComponent($1).path))?.count ?? 0)
        } ?? "F00"
        let dir = music.appendingPathComponent(folder)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var name: String
        repeat {
            name = String((0..<4).map { _ in letters.randomElement()! }) + "." + ext
        } while fm.fileExists(atPath: dir.appendingPathComponent(name).path)

        let rel = dir.appendingPathComponent(name).path.dropFirst(root.path.count)
        let location = rel.split(separator: "/").joined(separator: ":")
        return (dir.appendingPathComponent(name), ":" + location)
    }

    /// Converts to 256 kbps constant-bitrate AAC with macOS's own afconvert, then
    /// writes the original's tags into the new file so it stays labelled off the iPod too.
    nonisolated private static func convertToAAC(_ url: URL, tags: AudioTags) async -> URL? {
        let tmp = FileManager.default.temporaryDirectory
        let raw = tmp.appendingPathComponent(UUID().uuidString + ".m4a")
        let out = tmp.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: raw) }

        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "m4af", "-d", "aac", "-b", "256000", "-s", "0", url.path, raw.path]
        guard (try? convert.run()) != nil else { return nil }
        convert.waitUntilExit()
        guard convert.terminationStatus == 0,
              let session = AVAssetExportSession(asset: AVURLAsset(url: raw), presetName: AVAssetExportPresetPassthrough)
        else { return nil }

        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem? {
            guard !value.isEmpty else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            return m
        }
        session.metadata = [
            item(.iTunesMetadataSongName, tags.title), item(.iTunesMetadataArtist, tags.artist),
            item(.iTunesMetadataAlbum, tags.album), item(.iTunesMetadataUserGenre, tags.genre),
            item(.iTunesMetadataReleaseDate, tags.year > 0 ? "\(tags.year)" : ""),
        ].compactMap { $0 }
        session.outputURL = out
        session.outputFileType = .m4a
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { done.resume() }
        }
        return session.status == .completed ? out : nil
    }

    // MARK: Duplicates

    /// Songs that are the same recording: same artist and title (ignoring case,
    /// accents and punctuation) and lengths within 3 seconds of each other.
    /// Each group is sorted best first — playable, then highest bitrate, then largest.
    nonisolated static func duplicateGroups(_ tracks: [PodTrack]) -> [[PodTrack]] {
        func norm(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
        }
        let buckets = Dictionary(grouping: tracks.filter { !norm($0.title).isEmpty }) { norm($0.artist) + "\u{1}" + norm($0.title) }
        var groups: [[PodTrack]] = []
        for bucket in buckets.values where bucket.count > 1 {
            var run: [PodTrack] = []
            for t in bucket.sorted(by: { $0.duration < $1.duration }) {
                if let last = run.last, t.duration - last.duration > 3 {
                    if run.count > 1 { groups.append(run) }
                    run = []
                }
                run.append(t)
            }
            if run.count > 1 { groups.append(run) }
        }
        return groups.map { $0.sorted(by: isBetter) }
    }

    nonisolated static func isBetter(_ a: PodTrack, _ b: PodTrack) -> Bool {
        (a.exists ? 1 : 0, a.bitrate, a.size) > (b.exists ? 1 : 0, b.bitrate, b.size)
    }
}
