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
        .package(path: "../../Packages/CmuxMobileAuth"),
        .package(path: "../../Packages/CmuxMobileTerminal"),
        .package(path: "../../Packages/CmuxMobileTransport"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(
            name: "cmuxFeature",
            dependencies: [
                "CMUXAuthCore",
                "CMUXMobileCore",
                "CmuxMobileAuth",
                "CmuxMobileTerminal",
                "CmuxMobileTransport",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "cmuxFeatureTests",
            dependencies: [
                "cmuxFeature",
                "CMUXAuthCore",
                "CMUXMobileCore",
                "CmuxMobileAuth",
                "CmuxMobileTerminal",
                "CmuxMobileTransport",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
            ]
        ),
    ]
)
