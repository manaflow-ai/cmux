// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "cmuxMobileFeature",
    platforms: [.iOS("26.0")],
    products: [
        .library(
            name: "cmuxMobileFeature",
            targets: ["cmuxMobileFeature"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/CMUXAuthCore"),
        .package(path: "../../Packages/CMUXMobileSyncCore"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0"),
    ],
    targets: [
        .target(
            name: "cmuxMobileFeature",
            dependencies: [
                "CMUXAuthCore",
                "CMUXMobileSyncCore",
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ]
        ),
        .testTarget(
            name: "cmuxMobileFeatureTests",
            dependencies: [
                "cmuxMobileFeature",
                "CMUXMobileSyncCore",
            ]
        ),
    ]
)
