// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CelebrityBackend",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // Interface, error type, fake and sample data. Depends only on CelebrityCore.
        .library(name: "CelebrityBackend", targets: ["CelebrityBackend"]),
        // The Supabase implementation. The only product that links the SDK.
        .library(name: "CelebrityBackendSupabase", targets: ["CelebrityBackendSupabase"]),
    ],
    dependencies: [
        .package(path: "../CelebrityCore"),
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "CelebrityBackend",
            dependencies: ["CelebrityCore"]
        ),
        .testTarget(name: "CelebrityBackendTests", dependencies: ["CelebrityBackend"]),
        .target(
            name: "CelebrityBackendSupabase",
            dependencies: [
                "CelebrityBackend",
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(
            name: "CelebrityBackendSupabaseTests",
            dependencies: [
                "CelebrityBackendSupabase",
                "CelebrityBackend",
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
    ]
)
