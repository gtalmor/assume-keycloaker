// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AssumeKeycloaker",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure logic: config, parsers, TOTP, process runner, connectors. No UI.
        .target(name: "KeycloakerCore"),
        // The menu bar app (AppKit status item + SwiftUI popover).
        .executableTarget(name: "AssumeKeycloaker", dependencies: ["KeycloakerCore"]),
        .testTarget(name: "KeycloakerCoreTests", dependencies: ["KeycloakerCore"]),
    ]
)
