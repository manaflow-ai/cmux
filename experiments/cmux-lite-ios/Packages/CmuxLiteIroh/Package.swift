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
        .package(path: "../CmuxLiteSession"),
        .package(path: "../CmuxLiteTransport"),
        .package(
            url: "https://github.com/manaflow-ai/iroh-ffi.git",
            branch: "cmux-lite"
        ),
    ],
    targets: [
        .target(
            name: "CmuxLiteIroh",
            dependencies: [
                .product(name: "CmuxLiteProtocol", package: "CmuxLiteProtocol"),
                .product(name: "CmuxLiteSession", package: "CmuxLiteSession"),
                .product(name: "CmuxLiteTransport", package: "CmuxLiteTransport"),
                .product(name: "IrohLib", package: "iroh-ffi"),
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
                .product(name: "CmuxLiteSession", package: "CmuxLiteSession"),
                .product(name: "CmuxLiteTransport", package: "CmuxLiteTransport"),
                .product(name: "IrohLib", package: "iroh-ffi"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
