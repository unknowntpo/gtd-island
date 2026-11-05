// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GTDIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "GTDCore"),
        .executableTarget(name: "GTDIsland", dependencies: ["GTDCore"]),
        .testTarget(name: "GTDCoreTests", dependencies: ["GTDCore"]),
    ]
)
