// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxLiteSession",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxLiteSession",
            targets: ["CmuxLiteSession"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxLiteProtocol"),
    ],
    targets: [
        .target(
            name: "CmuxLiteSession",
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
            name: "CmuxLiteSessionTests",
            dependencies: [
                "CmuxLiteSession",
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
