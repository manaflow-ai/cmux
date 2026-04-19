// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "Runestone",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "Runestone", targets: ["Runestone"]),
        .library(name: "RunestoneCore", targets: ["RunestoneCore"]),
        .library(name: "RunestonePlatform", targets: ["RunestonePlatform"]),
        .library(name: "RunestoneUIMac", targets: ["RunestoneUIMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/tree-sitter", .upToNextMinor(from: "0.20.9"))
    ],
    targets: [
        .target(
            name: "Runestone",
            dependencies: [
                "RunestoneUIMac"
            ],
            path: "Sources/RunestoneFacade"
        ),
        .target(
            name: "RunestonePlatform",
            path: "Sources/RunestonePlatform"
        ),
        .target(
            name: "RunestoneCore",
            dependencies: [
                .product(name: "TreeSitter", package: "tree-sitter")
            ],
            path: "Sources/RunestoneCore"
        ),
        .target(
            name: "RunestoneUIMac",
            dependencies: [
                "RunestonePlatform",
                "RunestoneCore"
            ],
            path: "Sources/RunestoneMac"
        ),
    ]
)
