// swift-tools-version:5.10
// Agent Watch: a menu bar window onto claude-watcher (the same data the Paseo plugin shows).
import PackageDescription

let package = Package(
    name: "AgentWatch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AgentWatch", path: "Sources/AgentWatch"),
    ]
)
