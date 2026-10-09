// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AssumeCloaker",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure logic: config, parsers, TOTP, process runner, connectors. No UI.
        .target(name: "CloakerCore"),
        // The menu bar app (AppKit status item + SwiftUI popover).
        .executableTarget(name: "AssumeCloaker", dependencies: ["CloakerCore"]),
        .testTarget(name: "CloakerCoreTests", dependencies: ["CloakerCore"]),
    ]
)
