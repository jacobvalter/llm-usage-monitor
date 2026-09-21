// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LLMUsageMonitor",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .executable(name: "LLMUsageMonitor", targets: ["MacApp"]),
    ],
    targets: [
        .target(
            name: "UsageCore",
            path: "Sources/UsageCore"
        ),
        .executableTarget(
            name: "MacApp",
            dependencies: ["UsageCore"],
            path: "apps/MacApp/Sources"
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
