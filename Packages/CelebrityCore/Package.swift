// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CelebrityCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CelebrityCore", targets: ["CelebrityCore"]),
    ],
    targets: [
        .target(name: "CelebrityCore"),
        .testTarget(name: "CelebrityCoreTests", dependencies: ["CelebrityCore"]),
    ]
)
