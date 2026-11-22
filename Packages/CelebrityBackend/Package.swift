// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CelebrityBackend",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CelebrityBackend", targets: ["CelebrityBackend"]),
    ],
    dependencies: [
        .package(path: "../CelebrityCore"),
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "CelebrityBackend",
            dependencies: [
                "CelebrityCore",
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(name: "CelebrityBackendTests", dependencies: ["CelebrityBackend"]),
    ]
)
