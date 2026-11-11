// swift-tools-version: 6.2
import PackageDescription

// Everything runs on the main actor unless it says otherwise: the app is a menu-bar panel plus a
// few small services; file and network work is marked `nonisolated` and runs off the main thread.
let settings: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "AgentDot",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "AgentDot",
            path: "Sources/AgentDot",
            swiftSettings: settings
        ),
        .testTarget(
            name: "AgentDotTests",
            dependencies: ["AgentDot"],
            path: "Tests/AgentDotTests",
            swiftSettings: settings
        ),
    ]
)
