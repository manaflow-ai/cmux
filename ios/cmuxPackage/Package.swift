// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "cmuxFeature",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "cmuxFeature",
            targets: ["cmuxFeature"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/CMUXAuthCore"),
        .package(path: "../../Packages/CMUXMobileCore"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        // The same libghostty the Mac links. iOS feeds raw PTY bytes
        // (received over the network) directly into ghostty_surface_*
        // so the iPhone runs the exact same terminal core + Metal
        // renderer as the Mac. Module name is `GhosttyKit` per the
        // umbrella modulemap inside the xcframework.
        .binaryTarget(
            name: "GhosttyKit",
            path: "../../GhosttyKit.xcframework"
        ),
        .target(
            name: "cmuxFeature",
            dependencies: [
                "CMUXAuthCore",
                "CMUXMobileCore",
                "GhosttyKit",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "cmuxFeatureTests",
            dependencies: [
                "cmuxFeature",
                "CMUXAuthCore",
                "CMUXMobileCore",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
            ]
        ),
    ]
)
