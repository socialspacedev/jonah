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

    /// Every playlist in both playlist lists (see `podcastList`).
    static func playlists(_ root: DBNode) -> [DBNode] {
        [playlistList(root), podcastList(root)].compactMap { $0 }.flatMap { $0.children }.filter { $0.tag == "mhyp" }
    }

    /// The playlist list (mhsd type 2) the 3G and earlier read.
    static func playlistList(_ root: DBNode) -> DBNode? {
        root.children.first { $0.tag == "mhsd" && $0.u32(12) == 2 }?.children.first
    }

    /// A second copy of the playlists (mhsd type 3) that later iTunes writes, with
    /// podcasts grouped by show. Firmware that knows about podcasts reads this one
    /// instead, so every playlist edit is mirrored into it.
    static func podcastList(_ root: DBNode) -> DBNode? {
        root.children.first { $0.tag == "mhsd" && $0.u32(12) == 3 }?.children.first
    }

    /// The hidden playlist that lists every song; songs not in it don't appear on the iPod.
    static func masterPlaylist(_ root: DBNode) -> DBNode? {
        master(in: playlistList(root))
    }

    private static func master(in list: DBNode?) -> DBNode? {
        let all = list?.children.filter { $0.tag == "mhyp" } ?? []
        return all.first { $0.header.count > 20 && $0.header[20] == 1 } ?? all.first
    }

    static func string(_ mhod: DBNode) -> String? {
        let h = mhod.header
        guard h.count >= 40 else { return nil }
        let length = u32(h, 28)
        guard 40 + length <= h.count else { return nil }
        return String(bytes: h[40..<40 + length], encoding: u32(h, 24) == 2 ? .utf8 : .utf16LittleEndian)
    }

    /// iPod classic (2007) and later sign the database: a hashing scheme at +0x30
    /// of mhbd and a hash at +0x58. Any edit invalidates it and the iPod then shows
    /// no music, so these are never edited. Earlier iPods leave both zero.
    static func isChecksummed(_ root: DBNode) -> Bool {
        let h = root.header
        let scheme = h.count >= 0x32 ? Int(h[0x30]) | Int(h[0x31]) << 8 : 0
        let hash = h.count > 0x58 ? h[0x58..<min(0x6c, h.count)] : []
        return scheme != 0 || hash.contains { $0 != 0 }
    }

    // MARK: Playlists

    /// mhyp: hidden (master) flag at +20, 64-bit playlist id at +28, podcast flag at +42.
    static func playlistID(_ p: DBNode) -> UInt64 {
        p.header.count >= 36 ? (0..<8).reduce(UInt64(0)) { $0 | UInt64(p.header[28 + $1]) << (8 * UInt64($1)) } : 0
    }

    private static func isPodcast(_ p: DBNode) -> Bool { p.header.count >= 44 && (p.header[42] != 0 || p.header[43] != 0) }

    private static func mhods(_ n: DBNode, type: Int) -> [DBNode] {
        n.children.filter { $0.tag == "mhod" && $0.u32(12) == type }
    }

    private static func items(_ p: DBNode) -> [DBNode] { p.children.filter { $0.tag == "mhip" } }

    /// The playlists as the iPod lists them, without the hidden master.
    static func readPlaylists(_ root: DBNode) -> [PodPlaylist] {
        let master = masterPlaylist(root)
        return (playlistList(root)?.children ?? []).filter { $0.tag == "mhyp" && $0 !== master }.map { p in
            PodPlaylist(id: playlistID(p),
                        name: mhods(p, type: 1).first.flatMap(string) ?? "Untitled",
                        trackIDs: items(p).map { $0.u32(24) },
                        smart: !mhods(p, type: 50).isEmpty)
        }
    }

    enum PlaylistEdit: Sendable {
        case create(id: UInt64, name: String, tracks: [Int])
        case rename(UInt64, to: String)
        case delete(UInt64)
        /// Replaces the playlist's songs with these, in this order.
        case setTracks(UInt64, [Int])
    }

    static func apply(_ edit: PlaylistEdit, to root: DBNode) {
        guard let list = playlistList(root), let master = masterPlaylist(root) else { return }
        func find(_ id: UInt64) -> DBNode? { list.children.first { $0.tag == "mhyp" && $0 !== master && playlistID($0) == id } }
        let id: UInt64
        switch edit {
        case .create(let newID, let name, let tracks):
            // Modelled on the master so the firmware sees the header size it already reads.
            let p = DBNode(header: master.header)
            p.header[20] = 0
            put(&p.header, 24, Int(Date().timeIntervalSince1970) + macEpochOffset)
            withUnsafeBytes(of: newID.littleEndian) { p.header.replaceSubrange(28..<36, with: $0) }
            if p.header.count >= 48 {
                p.header[42] = 0; p.header[43] = 0
                put(&p.header, 44, 1)                     // sort: manual
            }
            p.children = [stringMhod(type: 1, name)] + mhods(master, type: 100).map(copy)
            list.children.append(p)
            setItems(p, tracks, root: root)
            id = newID
        case .rename(let pid, let name):
            guard let p = find(pid) else { return }
            if let i = p.children.firstIndex(where: { $0.tag == "mhod" && $0.u32(12) == 1 }) {
                p.children[i] = stringMhod(type: 1, name)
            } else {
                p.children.insert(stringMhod(type: 1, name), at: 0)
            }
            id = pid
        case .delete(let pid):
            list.children.removeAll { $0.tag == "mhyp" && $0 !== master && playlistID($0) == pid }
            id = pid
        case .setTracks(let pid, let tracks):
            guard let p = find(pid) else { return }
            setItems(p, tracks, root: root)
            id = pid
        }
        mirror(id, isMaster: false, in: root)
    }

    /// Keeps existing entries for songs that stay (so their bytes are untouched),
    /// makes new ones for songs that join, and renumbers positions.
    private static func setItems(_ p: DBNode, _ tracks: [Int], root: DBNode) {
        var pool = Dictionary(grouping: items(p)) { $0.u32(24) }
        var group = nextGroup(root)
        let entries = tracks.map { track -> DBNode in
            if let reuse = pool[track]?.first {
                pool[track]?.removeFirst()
                return reuse
            }
            defer { group += 1 }
            return playlistItem(track: track, group: group)
        }
        p.children = p.children.filter { $0.tag != "mhip" } + entries
        renumber(p)
        dropSortIndexes(root)
    }

    /// mhod 100 inside each mhip holds its position in the playlist.
    private static func renumber(_ p: DBNode) {
        for (i, item) in items(p).enumerated() {
            item.children.first { $0.tag == "mhod" && $0.u32(12) == 100 }?.setU32(24, i)
        }
    }

    /// Group ids (+20 in an mhip) are unique across every playlist.
    private static func nextGroup(_ root: DBNode) -> Int {
        let used = playlists(root).flatMap(items).map { $0.u32(20) }
        let tracks = trackList(root)?.children.map { $0.u32(16) } ?? []
        return max(used.max() ?? 0, tracks.max() ?? 0) + 1
    }

    private static func playlistItem(track: Int, group: Int) -> DBNode {
        var ip = [UInt8](repeating: 0, count: 0x4c)
        ip.replaceSubrange(0..<4, with: Array("mhip".utf8))
        put(&ip, 4, 0x4c)
        put(&ip, 20, group)
        put(&ip, 24, track)
        put(&ip, 28, Int(Date().timeIntervalSince1970) + macEpochOffset)
        var pos = [UInt8](repeating: 0, count: 0x2c)      // mhod 100: position, set by renumber
        pos.replaceSubrange(0..<4, with: Array("mhod".utf8))
        put(&pos, 4, 0x18)
        put(&pos, 8, 0x2c)
        put(&pos, 12, 100)
        return DBNode(header: ip, children: [DBNode(header: pos)])
    }

    /// Copies a playlist from the main list into the podcast list (type 3), replacing
    /// its old copy there, or removes it there if it's gone from the main list.
    /// The podcast playlist itself is grouped differently in type 3 and never copied.
    private static func mirror(_ id: UInt64, isMaster: Bool, in root: DBNode) {
        guard let main = playlistList(root), let other = podcastList(root) else { return }
        let source = isMaster ? master(in: main)
            : main.children.first { $0.tag == "mhyp" && !isPodcast($0) && $0 !== master(in: main) && playlistID($0) == id }
        let otherMaster = master(in: other)
        let index = isMaster ? otherMaster.flatMap { m in other.children.firstIndex { $0 === m } }
            : other.children.firstIndex { $0.tag == "mhyp" && !isPodcast($0) && $0 !== otherMaster && playlistID($0) == id }
        switch (source, index) {
        case let (source?, index?): other.children[index] = copy(source)
        case let (source?, nil): other.children.append(copy(source))
        case let (nil, index?): other.children.remove(at: index)
        case (nil, nil): break
        }
    }

    private static func copy(_ n: DBNode) -> DBNode {
        DBNode(header: n.header, children: n.children.map(copy))
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
            renumber(p)
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
        var soundCheck = 0, startMs = 0, stopMs = 0
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
        put(&h, 68, t.startMs)
        put(&h, 72, t.stopMs)
        put(&h, 76, t.soundCheck)
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
            master.children.append(playlistItem(track: id, group: nextGroup(root)))
            renumber(master)
            dropSortIndexes(root)
            mirror(0, isMaster: true, in: root)
        }
        return id
    }

    // MARK: Playback

    // mhit: file size at +36, start and stop times (ms) at +68 and +72, Sound Check at +76.

    /// Every song's file location, for picking which ones to measure.
    static func locations(_ root: DBNode) -> [String] {
        (trackList(root)?.children ?? []).compactMap { $0.children.first { $0.u32(12) == 2 }.flatMap(string) }
    }

    /// Fills in Sound Check where the song has none, and start and stop times where
    /// neither is set, so values set in iTunes are kept. Returns how many songs got each.
    @discardableResult
    static func apply(_ measured: [String: SongMeasurement], to root: DBNode) -> (levelled: Int, trimmed: Int) {
        var levelled = 0, trimmed = 0
        for t in trackList(root)?.children ?? [] {
            guard let loc = t.children.first(where: { $0.u32(12) == 2 }).flatMap(string),
                  let m = measured[loc], m.size == t.u32(36) else { continue }
            if t.u32(76) == 0 {
                t.setU32(76, Playback.soundCheck(m))
                levelled += 1
            }
            if t.u32(68) == 0 && t.u32(72) == 0 && (m.startMs > 0 || m.stopMs > 0) {
                t.setU32(68, m.startMs)
                t.setU32(72, m.stopMs)
                trimmed += 1
            }
        }
        return (levelled, trimmed)
    }

    /// Clears start and stop times that are exactly the ones Jonah set. Returns how many.
    @discardableResult
    static func removeTrims(_ measured: [String: SongMeasurement], from root: DBNode) -> Int {
        var removed = 0
        for t in trackList(root)?.children ?? [] {
            guard let loc = t.children.first(where: { $0.u32(12) == 2 }).flatMap(string),
                  let m = measured[loc], m.startMs > 0 || m.stopMs > 0,
                  t.u32(68) == m.startMs, t.u32(72) == m.stopMs else { continue }
            t.setU32(68, 0)
            t.setU32(72, 0)
            removed += 1
        }
        return removed
    }

    /// mhod 52/53 are pre-sorted browse indexes into the track list that later
    /// iTunes versions add; any edit makes them stale. 3G firmware predates them
    /// and sorts for itself, so they're removed rather than left pointing wrongly.
    private static func dropSortIndexes(_ root: DBNode) {
        for p in playlists(root) {
            p.children.removeAll { $0.tag == "mhod" && ($0.u32(12) == 52 || $0.u32(12) == 53) }
        }
    }

    static func stringMhod(type: Int, _ s: String) -> DBNode {
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
