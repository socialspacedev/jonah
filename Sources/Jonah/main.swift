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
//   Jonah --check <ipod-root>                    (can Jonah safely change this iPod?)
//   Jonah --dupes <ipod-root>                    (duplicate groups, best copy first)
//   Jonah --add <ipod-root> <file-or-folder>…    (add songs to the iPod)
//   Jonah --delete <ipod-root> <song-id>…        (delete songs; ids from --list)
//   Jonah --restore <ipod-root> <backup-folder>  (put a backed-up song list back)
let args = CommandLine.arguments
if args.count >= 3, ["--check", "--dupes", "--add", "--delete", "--restore"].contains(args[1]) {
    let root = URL(fileURLWithPath: args[2])
    switch args[1] {
    case "--check":
        print(Library.editProblem(root, fallback: false) ?? "OK: database round-trips byte for byte; editing allowed")
    case "--restore" where args.count >= 4:
        try Library.restore(URL(fileURLWithPath: args[3]), to: root)
        print("restored")
    case "--dupes":
        let (tracks, _) = await Library.load(root)
        for group in Library.duplicateGroups(tracks) {
            print(group.enumerated().map { i, t in "\(i == 0 ? "keep" : "drop") #\(t.id) \(t.artist) — \(t.title) \(t.bitrate)kbps \(t.kind)" }
                .joined(separator: "\n") + "\n")
        }
    default:
        let ids = args[1] == "--delete" ? Set(args.dropFirst(3).compactMap { Int($0) }) : []
        let files = args[1] == "--add" ? Library.audioFiles(in: args.dropFirst(3).map { URL(fileURLWithPath: $0) }) : []
        let result = try await Library.applyEdits(delete: ids, add: files, to: root) { label, _ in print("  \(label)") }
        print("added \(result.added), deleted \(result.deleted), skipped \(result.skipped), backup \(result.backup?.path ?? "-")")
    }
    exit(0)
}
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
        print("\(t.exists ? " " : "!") #\(t.id) \(t.artist) — \(t.album) — \(t.trackNumber) \(t.title)  [\(Int(t.duration))s, \(t.bitrate)kbps, \(t.fileURL.path.split(separator: "/").suffix(2).joined(separator: "/"))]")
    }
    if args[1] == "--export", args.count >= 4 {
        let result = await Library.export(tracks, to: URL(fileURLWithPath: args[3]), inFolders: !args.contains("--flat")) { _ in }
        print("copied \(result.copied), failed \(result.failed)")
    }
    exit(0)
}

JonahApp.main()
