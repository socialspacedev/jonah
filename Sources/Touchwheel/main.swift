import SwiftUI

struct TouchwheelApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 960, height: 620)
    }
}

// Command-line mode, handy for testing without the UI:
//   Touchwheel --list <ipod-root>
//   Touchwheel --export <ipod-root> <dest-folder>   (copies every song)
let args = CommandLine.arguments
if args.count >= 3, args[1] == "--list" || args[1] == "--export" {
    let root = URL(fileURLWithPath: args[2])
    let (tracks, fallback) = await Library.load(root)
    print("\(tracks.count) songs\(fallback ? " (from file tags)" : "")")
    for t in tracks {
        print("\(t.exists ? " " : "!") \(t.artist) — \(t.album) — \(t.trackNumber) \(t.title)  [\(Int(t.duration))s, \(t.fileURL.path)]")
    }
    if args[1] == "--export", args.count >= 4 {
        let result = await Library.export(tracks, to: URL(fileURLWithPath: args[3])) { _ in }
        print("copied \(result.copied), failed \(result.failed)")
    }
    exit(0)
}

TouchwheelApp.main()
