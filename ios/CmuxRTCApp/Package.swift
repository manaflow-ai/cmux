// swift-tools-version: 6.0

import PackageDescription

// The cmux-next iOS app over WebRTC (plans/cmux-next/ios-rtc.md section 7). The `cmux-ios` app
// target links only `CmuxRTCApp`. Module ownership: RTCAppAuth = the kept login screen and auth
// composition; RTCAppCore = Mac links, cmux-tui v12 client, host RPC client, stores (also builds
// for macOS so its tests run there); RTCAppTerminal = Ghostty surfaces and input; RTCAppViewer =
// files, Changes, video views; RTCAppSSH = direct SSH computers; RTCAppUI = screens.
let package = Package(
    name: "CmuxRTCApp",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CmuxRTCApp", targets: ["CmuxRTCApp"]),
    ],
    dependencies: [
        .package(path: "../../Packages/Shared/CmuxRTC"),
        .package(path: "../../Packages/Shared/CMUXAuthCore"),
        .package(path: "../../Packages/Shared/CmuxAuthRuntime"),
        .package(path: "../../Packages/Shared/CmuxGhosttyKit"),
        .package(path: "../../Packages/iOS/CmuxMobileSupport"),
        .package(path: "../../Packages/iOS/CmuxMobileSSH"),
        .package(path: "../../Packages/macOS/CmuxPhonePush"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(
            name: "CmuxRTCApp",
            dependencies: ["RTCAppUI", "RTCAppAuth", "RTCAppCore", "CmuxPhonePush"],
            swiftSettings: [.define("CMUX_DEV_AUTH", .when(configuration: .debug)), .swiftLanguageMode(.v6)]
        ),
        .target(
            name: "RTCAppAuth",
            dependencies: [
                "CMUXAuthCore",
                "CmuxAuthRuntime",
                "CmuxMobileSupport",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [.define("CMUX_DEV_AUTH", .when(configuration: .debug)), .swiftLanguageMode(.v6)]
        ),
        .target(
            name: "RTCAppCore",
            dependencies: [
                .product(name: "CmuxRTCSignal", package: "CmuxRTC"),
                .product(name: "CmuxRTCLink", package: "CmuxRTC"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "RTCAppTerminal",
            dependencies: ["RTCAppCore", "CmuxGhosttyKit", "CmuxMobileSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "RTCAppViewer",
            dependencies: ["RTCAppCore", "CmuxMobileSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "RTCAppSSH",
            dependencies: ["RTCAppCore", "CmuxMobileSSH"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "RTCAppUI",
            dependencies: ["RTCAppCore", "RTCAppAuth", "RTCAppTerminal", "RTCAppViewer", "RTCAppSSH", "CmuxMobileSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "RTCAppCoreTests", dependencies: ["RTCAppCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "RTCAppTerminalTests", dependencies: ["RTCAppTerminal"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "RTCAppViewerTests", dependencies: ["RTCAppViewer"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "RTCAppUITests", dependencies: ["RTCAppUI"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
