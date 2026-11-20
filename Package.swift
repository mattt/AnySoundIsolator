// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AnySoundIsolator",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "AnySoundIsolator", targets: ["AnySoundIsolator"])
    ],
    targets: [
        .target(name: "AnySoundIsolator"),
        .testTarget(
            name: "AnySoundIsolatorTests",
            dependencies: ["AnySoundIsolator"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
