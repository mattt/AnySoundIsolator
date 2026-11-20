// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AnySoundIsolator",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "AnySoundIsolator", targets: ["AnySoundIsolator"]),
        .executable(name: "silence", targets: ["silence"]),
    ],
    traits: [
        .trait(
            name: "MLX",
            description: "Adds InworldSoundIsolationModel, which runs Inworld's Voice Isolator with MLX."
        ),
        .default(enabledTraits: []),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        // The MLX trait is the only user of these two packages.
        // SwiftPM compiles MLX's Metal shaders from MLX Swift 0.31.6, which needs Swift 6.3.
        // Xcode also builds 0.31.4, the version that AnyDecisionModel's MLX trait resolves.
        .package(url: "https://github.com/ml-explore/mlx-swift", "0.31.4" ..< "0.34.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "1.0.1"),
    ],
    targets: [
        .target(
            name: "AnySoundIsolator",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift", condition: .when(traits: ["MLX"])),
                .product(name: "HuggingFace", package: "swift-huggingface", condition: .when(traits: ["MLX"])),
            ]
        ),
        .executableTarget(
            name: "silence",
            dependencies: [
                "AnySoundIsolator",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "AnySoundIsolatorTests",
            dependencies: [
                "AnySoundIsolator",
                .product(name: "MLX", package: "mlx-swift", condition: .when(traits: ["MLX"])),
                .product(name: "HuggingFace", package: "swift-huggingface", condition: .when(traits: ["MLX"])),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
