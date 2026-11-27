// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "StageKeeper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "stagekeeper", path: "Sources/StageKeeper"),
        .testTarget(name: "StageKeeperTests", dependencies: ["stagekeeper"], path: "Tests/StageKeeperTests"),
    ]
)
