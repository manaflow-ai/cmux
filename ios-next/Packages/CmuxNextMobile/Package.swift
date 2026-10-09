// swift-tools-version: 6.2

import PackageDescription

// cmux-next mobile: everything the two iOS app shells share. Module map and
// ownership: ios-next/README.md. Wire contract: ios-next/PROTOCOL.md.
let package = Package(
    name: "CmuxNextMobile",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "CNAppShell", targets: ["CNAppShell"]),
        .library(name: "CNCore", targets: ["CNCore"]),
        .library(name: "CNTransport", targets: ["CNTransport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC", exact: "154.0.0"),
        .package(path: "../../../Packages/Shared/CmuxGhosttyKit"),
        // Stack Auth, the same sign-in SDK (and accounts) as cmux iOS.
        .package(path: "../../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        // Codable mirrors of PROTOCOL.md and small shared helpers.
        .target(name: "CNCore"),
        // Transport-agnostic link (lanes, fragmentation, RPC, streams) and the
        // in-process loopback transport.
        .target(name: "CNTransport", dependencies: ["CNCore"]),
        // WebRTC data-channel transport plus the signaling client.
        .target(
            name: "CNTransportWebRTC",
            dependencies: [
                "CNCore", "CNTransport",
                .product(name: "WebRTC", package: "WebRTC", condition: .when(platforms: [.iOS])),
            ]
        ),
        // Backend HTTP client, auth session and keychain token store.
        .target(name: "CNBackend", dependencies: ["CNCore"]),
        // cmux-next tokens: colors, type, metrics, motion.
        .target(name: "CNDesign"),
        .target(
            name: "CNAuthUI",
            dependencies: [
                "CNCore", "CNBackend", "CNDesign",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease", condition: .when(platforms: [.iOS])),
            ],
            resources: [.process("Resources")]
        ),
        .target(name: "CNConversationsUI", dependencies: ["CNCore", "CNTransport", "CNDesign"]),
        .target(name: "CNAgentUI", dependencies: ["CNCore", "CNTransport", "CNDesign"]),
        .target(
            name: "CNTerminalUI",
            dependencies: [
                "CNCore", "CNTransport", "CNDesign",
                .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit", condition: .when(platforms: [.iOS])),
            ]
        ),
        .target(name: "CNBrowserUI", dependencies: ["CNCore", "CNTransport", "CNDesign"]),
        .target(name: "CNSettingsUI", dependencies: ["CNCore", "CNBackend", "CNTransport", "CNDesign"]),
        // Development fixture: an in-process host behind the loopback
        // transport, for previews, UI capture and offline UI tests.
        .target(name: "CNMockHost", dependencies: ["CNCore", "CNTransport"]),
        // App model plus the two navigation shells (drawer and native tabs).
        .target(
            name: "CNAppShell",
            dependencies: [
                "CNCore", "CNTransport", "CNTransportWebRTC", "CNBackend", "CNDesign",
                "CNAuthUI", "CNConversationsUI", "CNAgentUI", "CNTerminalUI",
                "CNBrowserUI", "CNSettingsUI", "CNMockHost",
            ]
        ),
        .testTarget(name: "CNCoreTests", dependencies: ["CNCore"]),
        .testTarget(name: "CNTransportTests", dependencies: ["CNCore", "CNTransport", "CNMockHost", "CNBackend"]),
    ],
    swiftLanguageModes: [.v6]
)
