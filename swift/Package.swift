// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JournalCLI",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "journal-cli",
            path: "Sources/journal-cli",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("LinkPresentation"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
)
