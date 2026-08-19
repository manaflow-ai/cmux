// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxLiteProtocol",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxLiteProtocol",
            targets: ["CmuxLiteProtocol"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxLiteProtocol",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxLiteProtocolTests",
            dependencies: ["CmuxLiteProtocol"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
