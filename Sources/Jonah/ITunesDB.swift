import Foundation

/// One song as the iPod knows it.
struct PodTrack: Identifiable, Hashable, Sendable {
    let id: Int
    var title: String
    var artist: String
    var album: String
    var genre: String
    var trackNumber: Int
    var discNumber: Int
    var year: Int
    var duration: TimeInterval
    var bitrate: Int
    var size: Int64
    /// Where the file lives, as the database writes it (":iPod_Control:Music:F03:ABCD.mp3").
    /// Stable for the life of the song, so it's what exports are remembered by.
    var location: String
    var fileURL: URL
    var exists: Bool

    var kind: String { fileURL.pathExtension.uppercased() }
}

enum PodError: LocalizedError {
    case notAnIPod
    case badDatabase
    case cantEdit(String)

    var errorDescription: String? {
        switch self {
        case .notAnIPod: "That folder has no iPod_Control folder in it."
        case .badDatabase: "The iPod's song database couldn't be read."
        case .cantEdit(let why): why
        }
    }
}

/// Reads the binary iTunesDB found on 1G–5G iPods (iPod_Control/iTunes/iTunesDB).
///
/// The file is a tree of little-endian chunks, each starting with a 4-char tag and
/// a header length. Songs live under mhbd → mhsd(type 1) → mhlt → mhit, and each
/// mhit carries its strings (title, artist, file path…) as child mhod chunks.
/// Read-only: we never write to the iPod.
enum ITunesDB {
    static func parse(_ data: Data, root: URL) throws -> [PodTrack] {
        let r = Reader(bytes: [UInt8](data))
        guard r.tag(0) == "mhbd", let header = r.u32(4) else { throw PodError.badDatabase }
        let end = min(r.u32(8) ?? r.count, r.count)

        var tracks: [PodTrack] = []
        var off = header
        while r.tag(off) == "mhsd", let h = r.u32(off + 4), let len = r.u32(off + 8), len > 0, off + len <= end {
            if r.u32(off + 12) == 1 {
                tracks += trackList(r, at: off + h, end: off + len, root: root)
            }
            off += len
        }
        return tracks
    }

    private static func trackList(_ r: Reader, at start: Int, end: Int, root: URL) -> [PodTrack] {
        guard r.tag(start) == "mhlt", let h = r.u32(start + 4), let count = r.u32(start + 8) else { return [] }
        var tracks: [PodTrack] = []
        var p = start + h
        for _ in 0..<count {
            guard r.tag(p) == "mhit", let hl = r.u32(p + 4), let tl = r.u32(p + 8), tl > 0, p + tl <= end else { break }
            if let t = track(r, at: p, headerLength: hl, root: root) { tracks.append(t) }
            p += tl
        }
        return tracks
    }

    private static func track(_ r: Reader, at p: Int, headerLength hl: Int, root: URL) -> PodTrack? {
        var strings: [Int: String] = [:]
        var q = p + hl
        for _ in 0..<(r.u32(p + 12) ?? 0) {
            guard r.tag(q) == "mhod", let tl = r.u32(q + 8), tl > 0 else { break }
            if let type = r.u32(q + 12), (1...5).contains(type) {
                strings[type] = r.string(at: q)
            }
            q += tl
        }
        // mhod 2 is the file path, written Mac-style: ":iPod_Control:Music:F03:ABCD.mp3"
        guard let location = strings[2], !location.isEmpty else { return nil }
        let url = resolve(location.split(separator: ":").map(String.init), under: root)

        return PodTrack(
            id: r.u32(p + 16) ?? q,
            title: strings[1] ?? url.deletingPathExtension().lastPathComponent,
            artist: strings[4] ?? "",
            album: strings[3] ?? "",
            genre: strings[5] ?? "",
            trackNumber: r.u32(p + 44) ?? 0,
            discNumber: hl > 96 ? (r.u32(p + 92) ?? 0) : 0,
            year: r.u32(p + 52) ?? 0,
            duration: TimeInterval(r.u32(p + 40) ?? 0) / 1000,
            bitrate: r.u32(p + 56) ?? 0,
            size: Int64(r.u32(p + 36) ?? 0),
            location: location,
            fileURL: url,
            exists: FileManager.default.fileExists(atPath: url.path)
        )
    }

    /// Joins path components, falling back to a case-insensitive match per folder —
    /// FAT-formatted ("Windows") iPods sometimes disagree with the database on case.
    static func resolve(_ parts: [String], under root: URL) -> URL {
        let direct = parts.reduce(root) { $0.appendingPathComponent($1) }
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        var url = root
        for part in parts {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            url.appendPathComponent(names.first { $0.caseInsensitiveCompare(part) == .orderedSame } ?? part)
        }
        return url
    }
}

private struct Reader {
    let bytes: [UInt8]
    var count: Int { bytes.count }

    func u32(_ o: Int) -> Int? {
        guard o >= 0, o + 4 <= bytes.count else { return nil }
        return Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
    }

    func tag(_ o: Int) -> String? {
        guard o >= 0, o + 4 <= bytes.count else { return nil }
        return String(bytes: bytes[o..<o + 4], encoding: .ascii)
    }

    /// String mhods: 24-byte header, then encoding (2 = UTF-8, else UTF-16LE) at +24,
    /// byte length at +28, and the text itself from +40.
    func string(at q: Int) -> String? {
        guard let encoding = u32(q + 24), let length = u32(q + 28) else { return nil }
        let start = q + 40
        guard start + length <= bytes.count else { return nil }
        let slice = Data(bytes[start..<start + length])
        let s = String(data: slice, encoding: encoding == 2 ? .utf8 : .utf16LittleEndian)
        return s?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
