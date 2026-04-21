// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "UsageCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
    ],
    targets: [
        .target(
            name: "UsageCore",
            path: "Sources/UsageCore"
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            path: "tests/UsageCoreTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
