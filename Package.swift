// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Jonah",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Jonah",
            path: "Sources/Jonah",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
