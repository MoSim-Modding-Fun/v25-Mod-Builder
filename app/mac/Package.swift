// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "V25ModBuilder",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "V25ModBuilder",
            path: "Sources/V25ModBuilder"
        )
    ]
)
