import Foundation

/// Remembers what Jonah measured in each song on each iPod, in
/// ~/Library/Application Support/Jonah/measured.json, keyed like `ExportLog`.
/// Songs already measured aren't read again, an interrupted run picks up where it
/// stopped, and Jonah can tell its own trims from ones set in iTunes.
enum MeasureLog {
    private static var file: URL { Library.supportFolder.appendingPathComponent("measured.json") }

    static func load(for root: URL) -> [String: SongMeasurement] {
        all()[key(root)] ?? [:]
    }

    static func add(_ measured: [String: SongMeasurement], for root: URL) {
        guard !measured.isEmpty else { return }
        update(root) { $0.merge(measured) { _, new in new } }
    }

    static func remove(_ locations: [String], for root: URL) {
        guard !locations.isEmpty else { return }
        update(root) { for l in locations { $0[l] = nil } }
    }

    private static func update(_ root: URL, _ change: (inout [String: SongMeasurement]) -> Void) {
        var log = all()
        var entries = log[key(root)] ?? [:]
        change(&entries)
        log[key(root)] = entries
        try? FileManager.default.createDirectory(at: Library.supportFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(log).write(to: file, options: .atomic)
    }

    private static func all() -> [String: [String: SongMeasurement]] {
        (try? JSONDecoder().decode([String: [String: SongMeasurement]].self, from: Data(contentsOf: file))) ?? [:]
    }

    private static func key(_ root: URL) -> String {
        let uuid = try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return uuid ?? root.lastPathComponent
    }
}
