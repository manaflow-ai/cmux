// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "cmuxFeature",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "cmuxFeature",
            targets: ["cmuxFeature"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/CMUXAuthCore"),
        .package(path: "../../Packages/CmuxAuthRuntime"),
        .package(path: "../../Packages/CMUXMobileCore"),
        .package(path: "../../Packages/CmuxMobileCamera"),
        .package(path: "../../Packages/CmuxMobileDiagnostics"),
        .package(path: "../../Packages/CmuxMobilePairedMac"),
        .package(path: "../../Packages/CmuxMobileRPC"),
        .package(path: "../../Packages/CmuxMobileShell"),
        .package(path: "../../Packages/CmuxMobileShellModel"),
        .package(path: "../../Packages/CmuxMobileShellUI"),
        .package(path: "../../Packages/CmuxMobileSupport"),
        .package(path: "../../Packages/CmuxMobileTerminal"),
        .package(path: "../../Packages/CmuxMobileTerminalKit"),
        .package(path: "../../Packages/CmuxMobileTransport"),
        .package(path: "../../Packages/CmuxMobileWorkspace"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(
            name: "cmuxFeature",
            dependencies: [
                "CMUXAuthCore",
                "CmuxAuthRuntime",
                "CMUXMobileCore",
                "CmuxMobileCamera",
                "CmuxMobileDiagnostics",
                "CmuxMobilePairedMac",
                "CmuxMobileRPC",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
                "CmuxMobileShellUI",
                "CmuxMobileSupport",
                "CmuxMobileTerminal",
                "CmuxMobileTerminalKit",
                "CmuxMobileTransport",
                "CmuxMobileWorkspace",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "cmuxFeatureTests",
            dependencies: [
                "cmuxFeature",
                "CMUXAuthCore",
                "CmuxAuthRuntime",
                "CMUXMobileCore",
                "CmuxMobileCamera",
                "CmuxMobileDiagnostics",
                "CmuxMobilePairedMac",
                "CmuxMobileRPC",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
                "CmuxMobileShellUI",
                "CmuxMobileSupport",
                "CmuxMobileTerminal",
                "CmuxMobileTerminalKit",
                "CmuxMobileTransport",
                "CmuxMobileWorkspace",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
            ]
        ),
    ]
)
