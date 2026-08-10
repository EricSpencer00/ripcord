// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ripcord",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RipcordKit", targets: ["RipcordKit"]),
        .executable(name: "ripcord-cli", targets: ["ripcord-cli"]),
        .executable(name: "Ripcord", targets: ["Ripcord"]),
    ],
    targets: [
        .target(name: "RipcordKit"),
        .executableTarget(name: "ripcord-cli", dependencies: ["RipcordKit"]),
        .executableTarget(name: "Ripcord", dependencies: ["RipcordKit"]),
        .testTarget(name: "RipcordKitTests", dependencies: ["RipcordKit"]),
    ]
)
