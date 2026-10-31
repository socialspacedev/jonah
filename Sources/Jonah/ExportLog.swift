import Foundation

/// Remembers which songs have been exported from each iPod, in
/// ~/Library/Application Support/Jonah/exported.json, keyed by the iPod's volume
/// id and the song's file location on it.
enum ExportLog {
    private static var file: URL { Library.supportFolder.appendingPathComponent("exported.json") }

    static func load(for root: URL) -> Set<String> {
        Set(all()[key(root)] ?? [])
    }

    static func add(_ locations: [String], for root: URL) {
        update(root) { $0.formUnion(locations) }
    }

    static func remove(_ locations: [String], for root: URL) {
        update(root) { $0.subtract(locations) }
    }

    private static func update(_ root: URL, _ change: (inout Set<String>) -> Void) {
        var log = all()
        var set = Set(log[key(root)] ?? [])
        change(&set)
        log[key(root)] = set.sorted()
        try? FileManager.default.createDirectory(at: Library.supportFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(log).write(to: file, options: .atomic)
    }

    private static func all() -> [String: [String]] {
        (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: file))) ?? [:]
    }

    private static func key(_ root: URL) -> String {
        let uuid = try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return uuid ?? root.lastPathComponent
    }
}
