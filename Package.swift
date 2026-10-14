// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fuse",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Fuse", targets: ["Fuse"]),
    ],
    targets: [
        .target(
            name: "Fuse",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .executableTarget(
            name: "fuse-benchmark",
            dependencies: ["Fuse"],
            path: "Sources/FuseBenchmark"
        ),
        .testTarget(
            name: "FuseTests",
            dependencies: ["Fuse"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
