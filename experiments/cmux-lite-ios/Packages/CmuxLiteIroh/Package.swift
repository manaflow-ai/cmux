// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxLiteIroh",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxLiteIroh",
            targets: ["CmuxLiteIroh"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxLiteProtocol"),
        .package(path: "../CmuxLiteTransport"),
    ],
    targets: [
        .target(
            name: "CmuxLiteIroh",
            dependencies: [
                .product(name: "CmuxLiteProtocol", package: "CmuxLiteProtocol"),
                .product(name: "CmuxLiteTransport", package: "CmuxLiteTransport"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxLiteIrohTests",
            dependencies: [
                "CmuxLiteIroh",
                .product(name: "CmuxLiteProtocol", package: "CmuxLiteProtocol"),
                .product(name: "CmuxLiteTransport", package: "CmuxLiteTransport"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
