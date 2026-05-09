// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "cmuxMobileFeature",
    platforms: [.iOS(.v17)],
    products: [
        .library(
            name: "cmuxMobileFeature",
            targets: ["cmuxMobileFeature"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/CMUXMobileSyncCore"),
    ],
    targets: [
        .target(
            name: "cmuxMobileFeature",
            dependencies: ["CMUXMobileSyncCore"]
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
