// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Touchwheel",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Touchwheel",
            path: "Sources/Touchwheel",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
