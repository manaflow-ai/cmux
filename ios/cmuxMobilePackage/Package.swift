// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "cmuxMobileFeature",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "cmuxMobileFeature",
            targets: ["cmuxMobileFeature"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/CMUXAuthCore"),
        .package(path: "../../Packages/CMUXMobileCore"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(
            name: "cmuxMobileFeature",
            dependencies: [
                "CMUXAuthCore",
                "CMUXMobileCore",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "cmuxMobileFeatureTests",
            dependencies: [
                "cmuxMobileFeature",
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
