// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexBarLite",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "CodexBarLite",
            path: "Sources/CodexBarLite"),
    ])
