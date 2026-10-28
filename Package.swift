// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CCNudge",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NudgeCore"),
        .executableTarget(name: "CCNudge", dependencies: ["NudgeCore"]),
        .testTarget(name: "NudgeCoreTests", dependencies: ["NudgeCore"]),
    ]
)
