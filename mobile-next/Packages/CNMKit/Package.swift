// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CNMKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v15),
    ],
    products: [
        .library(name: "CNMProtocol", targets: ["CNMProtocol"]),
        .library(name: "CNMTransport", targets: ["CNMTransport"]),
        .library(name: "CNMWebRTC", targets: ["CNMWebRTC"]),
        .library(name: "CNMBackend", targets: ["CNMBackend"]),
        .library(name: "CNMHost", targets: ["CNMHost"]),
        .executable(name: "cnm-host", targets: ["cnm-host"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", from: "130.0.0"),
    ],
    targets: [
        .target(name: "CNMProtocol", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "CNMTransport",
            dependencies: ["CNMProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CNMWebRTC",
            dependencies: [
                "CNMTransport",
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(name: "CNMBackend", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "CNMHost",
            dependencies: ["CNMProtocol", "CNMTransport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "cnm-host",
            dependencies: ["CNMHost", "CNMWebRTC", "CNMBackend", "CNMTransport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CNMKitTests",
            dependencies: ["CNMProtocol", "CNMTransport", "CNMHost", "CNMBackend"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
