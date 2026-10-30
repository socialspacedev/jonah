import SwiftUI

struct JonahApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 960, height: 620)
    }
}

// Command-line mode, handy for testing without the UI:
//   Jonah --list <ipod-root>
//   Jonah --export <ipod-root> <dest-folder>   (copies every song; add --flat for no folders)
//   Jonah --diagnose <ipod-root>                 (why songs show as missing)
let args = CommandLine.arguments
if args.count >= 3, args[1] == "--diagnose" {
    let root = URL(fileURLWithPath: args[2])
    let fm = FileManager.default
    let music = ITunesDB.resolve(["iPod_Control", "Music"], under: root)
    let folders = (try? fm.contentsOfDirectory(atPath: music.path))?.sorted() ?? []
    let onDisk = folders.reduce(0) { $0 + ((try? fm.contentsOfDirectory(atPath: music.appendingPathComponent($1).path))?.count ?? 0) }
    print("Music folder: \(music.path) — \(folders.count) folders, \(onDisk) files")
    print("Folders: \(folders.joined(separator: " "))")

    let data = try Data(contentsOf: root.appendingPathComponent("iPod_Control/iTunes/iTunesDB"))
    let tracks = try ITunesDB.parse(data, root: root)
    let missing = tracks.filter { !$0.exists }
    print("Database: \(tracks.count) songs, \(missing.count) missing")
    for t in missing.prefix(12) {
        let dir = t.fileURL.deletingLastPathComponent()
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let near = names.filter { $0.prefix(2).caseInsensitiveCompare(t.fileURL.lastPathComponent.prefix(2)) == .orderedSame }
        print("✗ \(t.title)\n    expected \(t.fileURL.path)\n    folder has \(names.count) files\(near.isEmpty ? "" : ", similar: \(near.prefix(5).joined(separator: " "))")")
    }
    exit(0)
}
if args.count >= 3, args[1] == "--list" || args[1] == "--export" {
    let root = URL(fileURLWithPath: args[2])
    let (tracks, fallback) = await Library.load(root)
    print("\(tracks.count) songs\(fallback ? " (from file tags)" : "")")
    for t in tracks {
        print("\(t.exists ? " " : "!") \(t.artist) — \(t.album) — \(t.trackNumber) \(t.title)  [\(Int(t.duration))s, \(t.fileURL.path)]")
    }
    if args[1] == "--export", args.count >= 4 {
        let result = await Library.export(tracks, to: URL(fileURLWithPath: args[3]), inFolders: !args.contains("--flat")) { _ in }
        print("copied \(result.copied), failed \(result.failed)")
    }
    exit(0)
}

JonahApp.main()
