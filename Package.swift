// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClankerTracker",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "ClankerCore"),
        .executableTarget(
            name: "ClankerTracker",
            dependencies: ["ClankerCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "ClankerCoreTests",
            dependencies: ["ClankerCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
