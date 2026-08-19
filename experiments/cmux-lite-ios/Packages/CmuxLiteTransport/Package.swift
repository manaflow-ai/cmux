// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxLiteTransport",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxLiteTransport",
            targets: ["CmuxLiteTransport"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxLiteProtocol"),
    ],
    targets: [
        .target(
            name: "CmuxLiteTransport",
            dependencies: [
                .product(name: "CmuxLiteProtocol", package: "CmuxLiteProtocol"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxLiteTransportTests",
            dependencies: [
                "CmuxLiteTransport",
                .product(name: "CmuxLiteProtocol", package: "CmuxLiteProtocol"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
