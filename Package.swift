// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "muse-canvas-mac",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure state machines. No I/O, no clock, no processes — fully testable.
        .target(name: "MuseCore"),
        // Effects: process supervision, health probes, filesystem, loopback status server.
        .target(name: "MuseKit", dependencies: ["MuseCore"],
                resources: [.copy("Resources/web"), .copy("Resources/english-overlay.js")]),
        // The agent- and human-facing CLI. Everything is also emitted as JSON.
        .executableTarget(name: "muse", dependencies: ["MuseCore", "MuseKit"]),
        // Native menu bar app (LSUIElement). Reads the same status JSON the CLI does.
        .executableTarget(name: "MuseBar", dependencies: ["MuseCore", "MuseKit"]),
        .testTarget(name: "MuseCoreTests", dependencies: ["MuseCore"]),
        .testTarget(name: "MuseKitTests", dependencies: ["MuseKit"]),
    ]
)
