// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudibleKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudibleKit", targets: ["AudibleKit"])
    ],
    targets: [
        .target(name: "AudibleKit"),
        .testTarget(name: "AudibleKitTests", dependencies: ["AudibleKit"])
    ]
)
