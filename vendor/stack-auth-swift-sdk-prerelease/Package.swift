// swift-tools-version: 6.2
import PackageDescription

let modernConcurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "StackAuth",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .watchOS(.v8),
        .tvOS(.v15),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "StackAuth",
            targets: ["StackAuth"]
        ),
    ],
    dependencies: [
        // Cross-platform crypto (provides CryptoKit API on Linux)
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "StackAuth",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/StackAuth",
            swiftSettings: modernConcurrencySettings
        ),
        .testTarget(
            name: "StackAuthTests",
            dependencies: ["StackAuth"],
            path: "Tests/StackAuthTests",
            swiftSettings: modernConcurrencySettings
        ),
    ]
)
