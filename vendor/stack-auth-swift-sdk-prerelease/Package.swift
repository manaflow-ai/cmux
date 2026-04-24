// swift-tools-version: 5.9
import PackageDescription

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
            path: "Sources/StackAuth"
        ),
        .testTarget(
            name: "StackAuthTests",
            dependencies: ["StackAuth"],
            path: "Tests/StackAuthTests"
        ),
    ]
)
