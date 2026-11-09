import AVFoundation
import Foundation
import Testing
@testable import Jonah

/// Builds a small iTunesDB the way iTunes 4 wrote one for a 3G: a track list and a
/// playlist list holding the hidden master, plus the type 3 podcast copy if asked.
private func makeDB(podcastList: Bool = false) throws -> DBNode {
    func node(_ tag: String, _ headerLength: Int, _ fields: [Int: Int] = [:], _ children: [DBNode] = []) -> DBNode {
        var h = [UInt8](repeating: 0, count: headerLength)
        h.replaceSubrange(0..<4, with: Array(tag.utf8))
        DBTree.put(&h, 4, headerLength)
        for (o, v) in fields { DBTree.put(&h, o, v) }
        return DBNode(header: h, children: children)
    }
    func master() -> DBNode {
        let m = node("mhyp", 0x6c, [28: 0x1234, 44: 1], [DBTree.stringMhod(type: 1, "Test iPod")])
        m.header[20] = 1
        return m
    }
    var sections = [
        node("mhsd", 0x60, [12: 1], [node("mhlt", 0x5c)]),
        node("mhsd", 0x60, [12: 2], [node("mhlp", 0x5c, [:], [master()])]),
    ]
    if podcastList { sections.append(node("mhsd", 0x60, [12: 3], [node("mhlp", 0x5c, [:], [master()])])) }
    let root = node("mhbd", 0x68, [12: 1, 16: 0x0c], sections)
    return try DBTree.parse(DBTree.serialise(root))
}

@discardableResult
private func addSong(_ tree: DBNode, _ title: String, file: String? = nil, seconds: Int = 200, bitrate: Int = 192) -> Int {
    DBTree.add(.init(title: title, artist: "Artist", album: "Album", genre: "Rock",
                     location: ":iPod_Control:Music:F00:\(file ?? title.uppercased()).mp3", ext: "mp3",
                     trackNumber: 3, year: 2004, bitrate: bitrate, sampleRate: 44100, size: 4_000_000,
                     durationMs: seconds * 1000), to: tree)!
}

/// Every playlist in a list, by name, with its song ids in order.
private func contents(_ list: DBNode?) -> [String: [Int]] {
    Dictionary((list?.children ?? []).filter { $0.tag == "mhyp" }.map { p in
        (p.children.first { $0.tag == "mhod" && $0.u32(12) == 1 }.flatMap(DBTree.string) ?? "",
         p.children.filter { $0.tag == "mhip" }.map { $0.u32(24) })
    }) { a, _ in a }
}

private func positions(_ list: DBNode?, _ name: String) -> [Int] {
    let p = list?.children.first { $0.children.first { $0.tag == "mhod" && $0.u32(12) == 1 }.flatMap(DBTree.string) == name }
    return (p?.children ?? []).filter { $0.tag == "mhip" }
        .map { $0.children.first { $0.u32(12) == 100 }?.u32(24) ?? -1 }
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("JonahTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite(.serialized)
struct DatabaseTests {
    @Test func roundTripsByteForByte() throws {
        let tree = try makeDB(podcastList: true)
        addSong(tree, "One")
        addSong(tree, "Two")
        let bytes = DBTree.serialise(tree)
        #expect(DBTree.serialise(try DBTree.parse(bytes)) == bytes)
    }

    @Test func addedSongsReadBack() throws {
        let tree = try makeDB()
        let id = addSong(tree, "Hello", seconds: 185, bitrate: 256)
        let tracks = try ITunesDB.parse(Data(DBTree.serialise(tree)), root: URL(fileURLWithPath: "/nonexistent"))
        #expect(tracks.count == 1)
        #expect(tracks[0].id == id)
        #expect(tracks[0].title == "Hello")
        #expect(tracks[0].artist == "Artist")
        #expect(tracks[0].duration == 185)
        #expect(tracks[0].bitrate == 256)
        #expect(tracks[0].location == ":iPod_Control:Music:F00:HELLO.mp3")
    }

    @Test func addedSongsReachThePodcastListToo() throws {
        let tree = try makeDB(podcastList: true)
        let a = addSong(tree, "A")
        let b = addSong(tree, "B")
        #expect(contents(DBTree.podcastList(tree))["Test iPod"] == [a, b])
        #expect(positions(DBTree.podcastList(tree), "Test iPod") == [0, 1])
    }

    @Test func createsRenamesAndDeletesPlaylists() throws {
        let tree = try makeDB(podcastList: true)
        let a = addSong(tree, "A"), b = addSong(tree, "B"), c = addSong(tree, "C")

        DBTree.apply(.create(id: 99, name: "Road Trip", tracks: [c, a]), to: tree)
        var playlists = DBTree.readPlaylists(try DBTree.parse(DBTree.serialise(tree)))
        #expect(playlists == [PodPlaylist(id: 99, name: "Road Trip", trackIDs: [c, a], smart: false)])
        #expect(contents(DBTree.podcastList(tree))["Road Trip"] == [c, a])

        DBTree.apply(.setTracks(99, [a, b, c]), to: tree)
        #expect(DBTree.readPlaylists(tree).first?.trackIDs == [a, b, c])
        #expect(positions(DBTree.playlistList(tree), "Road Trip") == [0, 1, 2])
        #expect(contents(DBTree.podcastList(tree))["Road Trip"] == [a, b, c])

        DBTree.apply(.rename(99, to: "Holiday"), to: tree)
        playlists = DBTree.readPlaylists(tree)
        #expect(playlists.map(\.name) == ["Holiday"])
        #expect(contents(DBTree.podcastList(tree))["Holiday"] == [a, b, c])

        DBTree.apply(.delete(99), to: tree)
        #expect(DBTree.readPlaylists(tree).isEmpty)
        #expect(contents(DBTree.podcastList(tree)).keys.sorted() == ["Test iPod"])
        #expect(contents(DBTree.playlistList(tree))["Test iPod"] == [a, b, c], "the master keeps every song")
        let bytes = DBTree.serialise(tree)
        #expect(DBTree.serialise(try DBTree.parse(bytes)) == bytes)
    }

    @Test func reorderingKeepsExistingEntries() throws {
        let tree = try makeDB()
        let a = addSong(tree, "A"), b = addSong(tree, "B")
        DBTree.apply(.create(id: 7, name: "Mix", tracks: [a, b]), to: tree)
        let before = DBTree.playlistList(tree)!.children.last!.children.filter { $0.tag == "mhip" }
        DBTree.apply(.setTracks(7, [b, a]), to: tree)
        let after = DBTree.playlistList(tree)!.children.last!.children.filter { $0.tag == "mhip" }
        #expect(after[0] === before[1] && after[1] === before[0])
        #expect(after.map { $0.u32(20) } == before.map { $0.u32(20) }.reversed(), "group ids travel with their entries")
    }

    @Test func deletingSongsTakesThemOutOfPlaylists() throws {
        let tree = try makeDB(podcastList: true)
        let a = addSong(tree, "A"), b = addSong(tree, "B"), c = addSong(tree, "C")
        DBTree.apply(.create(id: 5, name: "Mix", tracks: [a, b, c]), to: tree)
        let removed = DBTree.remove([b], from: tree)
        #expect(removed == [":iPod_Control:Music:F00:B.mp3"])
        #expect(DBTree.readPlaylists(tree).first?.trackIDs == [a, c])
        #expect(positions(DBTree.playlistList(tree), "Mix") == [0, 1])
        #expect(contents(DBTree.podcastList(tree))["Mix"] == [a, c])
        #expect(contents(DBTree.podcastList(tree))["Test iPod"] == [a, c])
    }

    @Test func groupsDuplicatesBestFirst() {
        func track(_ id: Int, _ title: String, _ artist: String, _ seconds: Double, _ bitrate: Int, exists: Bool = true) -> PodTrack {
            PodTrack(id: id, title: title, artist: artist, album: "", genre: "", trackNumber: 0, discNumber: 0, year: 0,
                     duration: seconds, bitrate: bitrate, size: 0, location: ":\(id)",
                     fileURL: URL(fileURLWithPath: "/\(id).mp3"), exists: exists)
        }
        let groups = Library.duplicateGroups([
            track(1, "Hey Jude", "The Beatles", 431, 128),
            track(2, "hey jude!", "the beatles", 433, 320),
            track(3, "Hey Jude", "The Beatles", 250, 320),           // a different edit: too far apart
            track(4, "Héy Jude", "The Beatles", 430, 999, exists: false),
            track(5, "Let It Be", "The Beatles", 243, 192),
        ])
        #expect(groups.count == 1)
        #expect(groups.first?.map(\.id) == [2, 1, 4])
    }
}

@Suite(.serialized)
struct EditingTests {
    init() throws {
        // Keeps backups made by the tests out of the real Application Support folder.
        setenv("JONAH_SUPPORT_FOLDER", try temporaryFolder().path, 1)
    }

    /// A fake iPod on disk with songs A and B, each with a real (tiny) file.
    private func makePod() throws -> (root: URL, a: Int, b: Int) {
        let root = try temporaryFolder().appendingPathComponent("TESTPOD")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("iPod_Control/iTunes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("iPod_Control/Music/F00"), withIntermediateDirectories: true)
        let tree = try makeDB(podcastList: true)
        let a = addSong(tree, "A", file: "AAAA"), b = addSong(tree, "B", file: "BBBB")
        try Data(DBTree.serialise(tree)).write(to: root.appendingPathComponent("iPod_Control/iTunes/iTunesDB"))
        for name in ["AAAA", "BBBB"] {
            try Data("x".utf8).write(to: root.appendingPathComponent("iPod_Control/Music/F00/\(name).mp3"))
        }
        return (root, a, b)
    }

    @Test func playlistEditsAreWrittenAndBackedUp() async throws {
        let (root, a, b) = try makePod()
        #expect(Library.editProblem(root, fallback: false) == nil)
        let result = try await Library.applyEdits(delete: [], add: [], playlists: [.create(id: 3, name: "Faves", tracks: [b, a])],
                                                  to: root) { _, _ in }
        #expect(result.playlistsChanged)
        #expect(Library.loadPlaylists(root).map(\.trackIDs) == [[b, a]])
        let backup = try #require(result.backup)
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("iTunesDB").path))
    }

    @Test func refusesToEditSignedDatabases() async throws {
        let (root, a, _) = try makePod()
        let db = root.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
        var bytes = [UInt8](try Data(contentsOf: db))
        bytes[0x30] = 1                                   // hashing scheme, as an iPod classic has
        try Data(bytes).write(to: db)
        #expect(Library.editProblem(root, fallback: false) != nil)
        await #expect(throws: PodError.self) {
            try await Library.applyEdits(delete: [a], add: [], to: root) { _, _ in }
        }
        #expect(try Data(contentsOf: db) == Data(bytes), "left untouched")
    }

    @Test func refusesToEditAShuffle() throws {
        let (root, _, _) = try makePod()
        try Data().write(to: root.appendingPathComponent("iPod_Control/iTunes/iTunesSD"))
        #expect(Library.editProblem(root, fallback: false)?.contains("shuffle") == true)
    }

    @Test func reportsSongFilesThatCouldNotBeDeleted() async throws {
        let (root, a, _) = try makePod()
        let folder = root.appendingPathComponent("iPod_Control/Music/F00")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        let result = try await Library.applyEdits(delete: [a], add: [], to: root) { _, _ in }
        #expect(result.deleted == 1)
        #expect(result.leftOver == ["AAAA.mp3"])
        let (tracks, _) = await Library.load(root)
        #expect(tracks.map(\.title) == ["B"])
    }

    @Test func prunesOldBackupsOfThisIPodOnly() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Library.backupsFolder, withIntermediateDirectories: true)
        for i in 0..<(Library.backupsKept + 5) {
            let name = String(format: "PRUNEPOD 2026-01-01 %06d", i)
            try fm.createDirectory(at: Library.backupsFolder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: Library.backupsFolder.appendingPathComponent("PRUNEPOD MINI 2020-01-01 000000"),
                               withIntermediateDirectories: true)
        Library.pruneBackups(of: URL(fileURLWithPath: "/Volumes/PRUNEPOD"))
        let left = try fm.contentsOfDirectory(atPath: Library.backupsFolder.path)
        #expect(left.filter { !$0.contains("MINI") }.count == Library.backupsKept)
        #expect(!left.contains("PRUNEPOD 2026-01-01 000000"), "the oldest go first")
        #expect(left.contains("PRUNEPOD MINI 2020-01-01 000000"), "another iPod's backups are left alone")
    }

    @Test func convertedFilesKeepTheirTags() async throws {
        let source = try temporaryFolder().appendingPathComponent("tone.caf")
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
            buffer.frameLength = 44100
            try file.write(from: buffer)
        }
        var tags = AudioTags()
        tags.title = "Converted"
        tags.artist = "Someone"
        tags.trackNumber = 7
        tags.year = 1999
        let output = try #require(await Library.convertToAAC(source, tags: tags))
        defer { try? FileManager.default.removeItem(at: output) }
        let back = await AudioTags.read(output)
        #expect(back.title == "Converted")
        #expect(back.artist == "Someone")
        #expect(back.trackNumber == 7)
        #expect(back.year == 1999)
    }
}
