// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SuperSpotlight",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SuperSpotlightCore"),
        .executableTarget(name: "SuperSpotlight", dependencies: ["SuperSpotlightCore"]),
        .executableTarget(name: "ssbench", dependencies: ["SuperSpotlightCore"]),
        .executableTarget(name: "sscheck", dependencies: ["SuperSpotlightCore"]),
    ]
)
