import Foundation

/// The iTunesDB as an editable tree of chunks. Every byte Jonah doesn't understand
/// is carried through untouched; only lengths and counts are recomputed on write.
/// `Library` refuses to edit an iPod unless parse → serialise reproduces its
/// database byte for byte, so a layout this code doesn't expect can't be damaged.
final class DBNode {
    var header: [UInt8]
    var children: [DBNode]

    init(header: [UInt8], children: [DBNode] = []) {
        self.header = header
        self.children = children
    }

    var tag: String { String(bytes: header[0..<4], encoding: .ascii) ?? "" }
    func u32(_ o: Int) -> Int { DBTree.u32(header, o) }
    func setU32(_ o: Int, _ v: Int) { DBTree.put(&header, o, v) }
}

enum DBTree {
    /// Lists hold a child count at +8 and their children follow the header.
    private static let lists: Set<String> = ["mhlt", "mhlp", "mhla"]
    /// Containers hold their total length at +8 and their children inside it.
    private static let containers: Set<String> = ["mhbd", "mhsd", "mhit", "mhyp", "mhip"]

    // MARK: Parse / serialise

    static func parse(_ bytes: [UInt8]) throws -> DBNode {
        let (root, end) = try node(bytes, at: 0)
        guard root.tag == "mhbd", end == bytes.count else { throw PodError.badDatabase }
        return root
    }

    private static func node(_ b: [UInt8], at off: Int) throws -> (DBNode, Int) {
        guard off + 12 <= b.count else { throw PodError.badDatabase }
        let tag = String(bytes: b[off..<off + 4], encoding: .ascii) ?? ""
        let hl = u32(b, off + 4)
        let third = u32(b, off + 8)

        if lists.contains(tag) {
            guard hl >= 12, off + hl <= b.count else { throw PodError.badDatabase }
            let n = DBNode(header: Array(b[off..<off + hl]))
            var p = off + hl
            for _ in 0..<third {
                let (child, next) = try node(b, at: p)
                n.children.append(child)
                p = next
            }
            return (n, p)
        }
        guard third >= 12, off + third <= b.count else { throw PodError.badDatabase }
        if containers.contains(tag) {
            guard hl >= 12, hl <= third else { throw PodError.badDatabase }
            let n = DBNode(header: Array(b[off..<off + hl]))
            var p = off + hl
            while p < off + third {
                let (child, next) = try node(b, at: p)
                n.children.append(child)
                p = next
            }
            guard p == off + third else { throw PodError.badDatabase }
            return (n, p)
        }
        // Leaf (mhod and anything unknown): kept as raw bytes.
        return (DBNode(header: Array(b[off..<off + third])), off + third)
    }

    static func serialise(_ n: DBNode) -> [UInt8] {
        let tag = n.tag
        if lists.contains(tag) {
            n.setU32(8, n.children.count)
            return n.header + n.children.flatMap(serialise)
        }
        guard containers.contains(tag) else { return n.header }
        let body = n.children.flatMap(serialise)
        n.setU32(8, n.header.count + body.count)
        switch tag {
        case "mhit", "mhip":
            n.setU32(12, n.children.count)
        case "mhyp":
            n.setU32(12, n.children.filter { $0.tag == "mhod" }.count)
            n.setU32(16, n.children.filter { $0.tag == "mhip" }.count)
        default: break
        }
        return n.header + body
    }

    // MARK: Navigation

    static func trackList(_ root: DBNode) -> DBNode? {
        root.children.first { $0.tag == "mhsd" && $0.u32(12) == 1 }?.children.first
    }

    static func playlists(_ root: DBNode) -> [DBNode] {
        root.children
            .filter { $0.tag == "mhsd" && ($0.u32(12) == 2 || $0.u32(12) == 3) }
            .flatMap { $0.children.first?.children ?? [] }
            .filter { $0.tag == "mhyp" }
    }

    /// The hidden playlist that lists every song; songs not in it don't appear on the iPod.
    static func masterPlaylist(_ root: DBNode) -> DBNode? {
        let main = root.children.first { $0.tag == "mhsd" && $0.u32(12) == 2 }?.children.first?.children ?? []
        return main.first { $0.tag == "mhyp" && $0.header.count > 20 && $0.header[20] == 1 } ?? main.first
    }

    static func string(_ mhod: DBNode) -> String? {
        let h = mhod.header
        guard h.count >= 40 else { return nil }
        let length = u32(h, 28)
        guard 40 + length <= h.count else { return nil }
        return String(bytes: h[40..<40 + length], encoding: u32(h, 24) == 2 ? .utf8 : .utf16LittleEndian)
    }

    // MARK: Edits

    /// Removes songs and every playlist entry pointing at them. Returns their file
    /// locations (":iPod_Control:Music:F03:ABCD.mp3") so the caller can delete them.
    static func remove(_ ids: Set<Int>, from root: DBNode) -> [String] {
        guard let list = trackList(root) else { return [] }
        var locations: [String] = []
        list.children.removeAll { t in
            guard ids.contains(t.u32(16)) else { return false }
            if let loc = t.children.first(where: { $0.u32(12) == 2 }).flatMap(string) { locations.append(loc) }
            return true
        }
        for p in playlists(root) {
            p.children.removeAll { $0.tag == "mhip" && ids.contains($0.u32(24)) }
        }
        dropSortIndexes(root)
        return locations
    }

    struct NewTrack {
        var title, artist, album, genre: String
        var location: String
        var ext: String
        var trackNumber, year, bitrate, sampleRate, size: Int
        var durationMs: Int
    }

    /// Appends a song to the track list and the master playlist. Returns its id.
    @discardableResult
    static func add(_ t: NewTrack, to root: DBNode) -> Int? {
        guard let list = trackList(root) else { return nil }
        let id = (list.children.map { $0.u32(16) }.max() ?? 0) + 1
        let now = Int(Date().timeIntervalSince1970) + macEpochOffset

        // Same header size as the songs already there, so the firmware sees a familiar layout.
        var h = [UInt8](repeating: 0, count: max(list.children.first?.header.count ?? 0x9c, 0x9c))
        h.replaceSubrange(0..<4, with: Array("mhit".utf8))
        put(&h, 4, h.count)
        put(&h, 16, id)
        put(&h, 20, 1)                                    // visible
        put(&h, 24, fourCC[t.ext] ?? fourCC["mp3"]!)
        if t.ext == "mp3" { h[28] = 1; h[29] = 1 }
        put(&h, 32, now)                                  // modified
        put(&h, 36, t.size)
        put(&h, 40, t.durationMs)
        put(&h, 44, t.trackNumber)
        put(&h, 52, t.year)
        put(&h, 56, t.bitrate)
        put(&h, 60, t.sampleRate << 16)
        put(&h, 104, now)                                 // added
        if h.count >= 120 {                               // 64-bit database id
            var dbid = UInt64.random(in: 1...UInt64.max)
            withUnsafeBytes(of: &dbid) { h.replaceSubrange(112..<120, with: $0) }
        }

        let kinds = ["mp3": "MPEG audio file", "wav": "WAV audio file", "aif": "AIFF audio file", "aiff": "AIFF audio file"]
        let strings: [(Int, String)] = [
            (1, t.title), (2, t.location), (3, t.album), (4, t.artist), (5, t.genre),
            (6, kinds[t.ext] ?? "AAC audio file"),
        ]
        let mhods = strings.filter { !$0.1.isEmpty }.map { stringMhod(type: $0.0, $0.1) }
        list.children.append(DBNode(header: h, children: mhods))

        if let master = masterPlaylist(root) {
            let items = master.children.filter { $0.tag == "mhip" }
            let group = (playlists(root).flatMap { $0.children }.filter { $0.tag == "mhip" }.map { $0.u32(20) }.max() ?? id) + 1
            var ip = [UInt8](repeating: 0, count: 0x4c)
            ip.replaceSubrange(0..<4, with: Array("mhip".utf8))
            put(&ip, 4, 0x4c)
            put(&ip, 20, group)
            put(&ip, 24, id)
            put(&ip, 28, now)
            var pos = [UInt8](repeating: 0, count: 0x2c)   // mhod 100: position in playlist
            pos.replaceSubrange(0..<4, with: Array("mhod".utf8))
            put(&pos, 4, 0x18)
            put(&pos, 8, 0x2c)
            put(&pos, 12, 100)
            put(&pos, 24, items.count)
            master.children.append(DBNode(header: ip, children: [DBNode(header: pos)]))
            dropSortIndexes(root)
        }
        return id
    }

    /// mhod 52/53 are pre-sorted browse indexes into the track list that later
    /// iTunes versions add; any edit makes them stale. 3G firmware predates them
    /// and sorts for itself, so they're removed rather than left pointing wrongly.
    private static func dropSortIndexes(_ root: DBNode) {
        for p in playlists(root) {
            p.children.removeAll { $0.tag == "mhod" && ($0.u32(12) == 52 || $0.u32(12) == 53) }
        }
    }

    private static func stringMhod(type: Int, _ s: String) -> DBNode {
        let text = Array(s.utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        var h = [UInt8](repeating: 0, count: 40)
        h.replaceSubrange(0..<4, with: Array("mhod".utf8))
        put(&h, 4, 0x18)
        put(&h, 8, 40 + text.count)
        put(&h, 12, type)
        put(&h, 24, 1)                                    // UTF-16
        put(&h, 28, text.count)
        return DBNode(header: h + text)
    }

    // MARK: Bytes

    static let macEpochOffset = 2_082_844_800

    /// File type marker: the 4CC as a big-endian number, stored little-endian.
    private static let fourCC: [String: Int] = [
        "mp3": 0x4d50_3320, "m4a": 0x4d34_4120, "m4b": 0x4d34_4220, "m4p": 0x4d34_5020,
        "wav": 0x5741_5620, "aif": 0x4149_4646, "aiff": 0x4149_4646,
    ]

    static func u32(_ b: [UInt8], _ o: Int) -> Int {
        guard o >= 0, o + 4 <= b.count else { return 0 }
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    static func put(_ b: inout [UInt8], _ o: Int, _ v: Int) {
        guard o >= 0, o + 4 <= b.count else { return }
        let v = UInt32(truncatingIfNeeded: v)
        for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
    }
}
