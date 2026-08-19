// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudibleKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudibleKit", targets: ["AudibleKit"]),
        .executable(name: "audible-cli", targets: ["audible-cli"])
    ],
    targets: [
        .target(name: "AudibleKit"),
        .executableTarget(name: "audible-cli", dependencies: ["AudibleKit"]),
        .testTarget(name: "AudibleKitTests", dependencies: ["AudibleKit"])
    ]
)
