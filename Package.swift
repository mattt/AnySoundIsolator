// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AnySoundIsolator",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "AnySoundIsolator", targets: ["AnySoundIsolator"]),
        .executable(name: "hush", targets: ["hush"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2")
    ],
    targets: [
        .target(name: "AnySoundIsolator"),
        .executableTarget(
            name: "hush",
            dependencies: [
                "AnySoundIsolator",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "AnySoundIsolatorTests",
            dependencies: ["AnySoundIsolator"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
