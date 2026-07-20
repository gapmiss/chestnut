// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chestnut",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Chestnut")
    ]
)
