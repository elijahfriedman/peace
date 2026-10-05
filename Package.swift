// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "peace",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "peace", path: "Sources/peace")
    ]
)
