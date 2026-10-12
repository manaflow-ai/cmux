// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxNativeHost",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CmuxNativeHost", targets: ["CmuxNativeHost"]),
        .executable(name: "cmux-native-host", targets: ["cmux-native-host"]),
    ],
    dependencies: [
        .package(path: "../Shared"),
    ],
    targets: [
        .target(
            name: "CmuxNativeHost",
            dependencies: [
                .product(name: "CmuxNativeWire", package: "Shared"),
                .product(name: "CmuxNativeLink", package: "Shared"),
            ]
        ),
        .executableTarget(
            name: "cmux-native-host",
            dependencies: [
                "CmuxNativeHost",
                .product(name: "CmuxNativeWire", package: "Shared"),
                .product(name: "CmuxNativeLink", package: "Shared"),
            ]
        ),
        .testTarget(
            name: "CmuxNativeHostTests",
            dependencies: [
                "CmuxNativeHost",
                .product(name: "CmuxNativeWire", package: "Shared"),
                .product(name: "CmuxNativeLink", package: "Shared"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
