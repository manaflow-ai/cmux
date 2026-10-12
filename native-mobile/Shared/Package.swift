// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxNativeShared",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [
        .library(name: "CmuxNativeWire", targets: ["CmuxNativeWire"]),
        .library(name: "CmuxNativeLink", targets: ["CmuxNativeLink"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC", exact: "155.0.0"),
    ],
    targets: [
        .target(name: "CmuxNativeWire"),
        .target(
            name: "CmuxNativeLink",
            dependencies: [
                "CmuxNativeWire",
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
        .testTarget(name: "CmuxNativeWireTests", dependencies: ["CmuxNativeWire"]),
        .testTarget(name: "CmuxNativeLinkTests", dependencies: ["CmuxNativeLink", "CmuxNativeWire"]),
    ],
    swiftLanguageModes: [.v6]
)
