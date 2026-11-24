// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CertyPie",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "CertyPie", path: "Sources/CertyPie")
    ]
)
