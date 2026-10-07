// swift-tools-version: 6.0

import PackageDescription

// The rewritten iOS app's modules (plans/cmux-next/ios-rewrite.md). The app
// target in ios/cmux-ios.xcodeproj links only `CmuxiOSApp`.
let package = Package(
    name: "CmuxiOS",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "CmuxiOSApp", targets: ["CmuxiOSApp"]),
    ],
    dependencies: [
        .package(path: "../../Packages/Shared/CmuxHomeCore"),
        .package(path: "../../Packages/Shared/CmuxHomeRender"),
        .package(path: "../../Packages/Shared/CmuxFeedPushCore"),
        .package(path: "../../Packages/Shared/CmuxInstallAuthCore"),
        .package(path: "../../Packages/Shared/CmuxTextConfirmCore"),
        .package(path: "../../Packages/Shared/CMUXAuthCore"),
        .package(path: "../../Packages/Shared/CMUXMobileCore"),
        .package(path: "../../Packages/Shared/CmuxAuthRuntime"),
        .package(path: "../../Packages/Shared/CmuxTerminalStream"),
        .package(path: "../../Packages/Shared/CmuxTerminalRenderCore"),
        .package(path: "../../Packages/Shared/CmuxTheme"),
        .package(path: "../../Packages/Shared/CmuxGhosttyKit"),
        .package(path: "../../Packages/iOS/CmuxMobileSupport"),
        .package(path: "../../Packages/iOS/CmuxMobileSSH"),
        .package(path: "../../Packages/macOS/CmuxPhonePush"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
        .package(path: "../../Packages/Shared/CmuxSentryTelemetry"),
        // Same range as CmuxSentryTelemetry; ios/cmux.xcworkspace pins the version.
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", "9.3.0"..<"9.29.0"),
    ],
    targets: [
        .target(
            name: "CmuxiOSApp",
            dependencies: [
                "CmuxiOSAuth",
                "CmuxHomeUI",
                "CmuxiOSTerminal",
                .product(name: "CmuxTerminalRenderCore", package: "CmuxTerminalRenderCore"),
                "CmuxiOSDesign",
                "CmuxiOSPush",
                "CmuxiOSIdentity",
                "CmuxiOSShell",
                "CmuxiOSFeatureKit",
                "CmuxiOSFeed",
                "CmuxiOSFeedCloud",
                "CmuxiOSPlatform",
                "CmuxiOSPlatformUI",
                "CmuxiOSCrashReporting",
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
                "CmuxiOSOnboarding",
                "CmuxiOSOnboardingCore",
                "CmuxiOSSSH",
                "CmuxiOSSSHCore",
                .product(name: "CmuxFeedPushCore", package: "CmuxFeedPushCore"),
                "CmuxiOSTextConfirm",
                .product(name: "CmuxTextConfirmCore", package: "CmuxTextConfirmCore"),
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxPhonePush", package: "CmuxPhonePush"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxiOSAuth",
            dependencies: [
                .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
                .product(name: "CmuxAuthRuntime", package: "CmuxAuthRuntime"),
                .product(name: "CmuxMobileSupport", package: "CmuxMobileSupport"),
                .product(name: "CmuxPhonePush", package: "CmuxPhonePush"),
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // The `42` debug sign-in shortcut and auto-login exist only in DEBUG.
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "CmuxHomeUI",
            dependencies: [
                "CmuxiOSDesign",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxHomeUITests",
            dependencies: [
                "CmuxHomeUI",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxiOSTerminal",
            dependencies: [
                .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit"),
                .product(name: "CmuxTerminalStream", package: "CmuxTerminalStream"),
                .product(name: "CmuxTerminalRenderCore", package: "CmuxTerminalRenderCore"),
                .product(name: "CmuxTheme", package: "CmuxTheme"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            // The static library carries C++ objects (glslang).
            linkerSettings: [.linkedLibrary("c++")]
        ),
        // GhosttyNextKit comes from Packages/Shared/CmuxGhosttyKit, the one
        // pin the Mac and iOS apps share (plans/cmux-next/ghostty-next-switch.md).
        .testTarget(
            name: "CmuxiOSTerminalTests",
            dependencies: [
                "CmuxiOSTerminal",
                .product(name: "CmuxTerminalRenderCore", package: "CmuxTerminalRenderCore"),
                .product(name: "CmuxTerminalStream", package: "CmuxTerminalStream"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxiOSPush",
            dependencies: [
                .product(name: "CmuxFeedPushCore", package: "CmuxFeedPushCore"),
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxiOSIdentity",
            dependencies: [
                .product(name: "CmuxInstallAuthCore", package: "CmuxInstallAuthCore"),
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxiOSTextConfirm",
            dependencies: [.product(name: "CmuxTextConfirmCore", package: "CmuxTextConfirmCore")],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxiOSDesign",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Feature seams (protocols, value types, mocks) for the ios-next
        // feature lanes; Foundation only (plans/cmux-next/ios-next/a1-shell.md).
        .target(
            name: "CmuxiOSFeatureKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxiOSFeatureKitTests",
            dependencies: ["CmuxiOSFeatureKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // First-run onboarding (plans/cmux-next/ios-next/c10-onboarding.md):
        // the platform-neutral flow, persistence and pairing projection...
        .target(
            name: "CmuxiOSOnboardingCore",
            dependencies: ["CmuxiOSFeatureKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxiOSOnboardingCoreTests",
            dependencies: ["CmuxiOSOnboardingCore", "CmuxiOSFeatureKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // ...and its screens.
        .target(
            name: "CmuxiOSOnboarding",
            dependencies: ["CmuxiOSOnboardingCore", "CmuxiOSFeatureKit", "CmuxiOSDesign"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Lane C9 (plans/cmux-next/ios-next/c9-ssh.md): SSH hosts store,
        // config import, known_hosts and TOFU, and the `.local` byte source.
        // No UIKit, so its tests also run on macOS.
        .target(
            name: "CmuxiOSSSHCore",
            dependencies: [
                "CmuxiOSFeatureKit",
                .product(name: "CmuxMobileSSH", package: "CmuxMobileSSH"),
                .product(name: "CmuxTerminalRenderCore", package: "CmuxTerminalRenderCore"),
                .product(name: "CmuxTerminalStream", package: "CmuxTerminalStream"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxiOSSSHCoreTests",
            dependencies: [
                "CmuxiOSSSHCore",
                "CmuxiOSFeatureKit",
                .product(name: "CmuxMobileSSH", package: "CmuxMobileSSH"),
                .product(name: "CmuxTerminalRenderCore", package: "CmuxTerminalRenderCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The Hosts tab, host editor, keys, trust prompts and SSH terminal screen.
        .target(
            name: "CmuxiOSSSH",
            dependencies: [
                "CmuxiOSSSHCore",
                "CmuxiOSFeatureKit",
                "CmuxiOSDesign",
                "CmuxiOSTerminal",
                .product(name: "CmuxMobileSSH", package: "CmuxMobileSSH"),
                .product(name: "CmuxTerminalRenderCore", package: "CmuxTerminalRenderCore"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Lane C6 (plans/cmux-next/ios-next/c6-feed.md): the Feed tab's
        // model (mirror + intent log, filters, sections; Foundation only),
        // the FeedDO wire source, and the UIKit screen.
        .target(
            name: "CmuxiOSFeedModel",
            dependencies: ["CmuxiOSFeatureKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxiOSFeedModelTests",
            dependencies: ["CmuxiOSFeedModel", "CmuxiOSFeatureKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxiOSFeedCloud",
            dependencies: ["CmuxiOSFeatureKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxiOSFeedCloudTests",
            dependencies: ["CmuxiOSFeedCloud", "CmuxiOSFeatureKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxiOSFeed",
            dependencies: ["CmuxiOSDesign", "CmuxiOSFeatureKit", "CmuxiOSFeedModel"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Root navigation, placeholder screens, feature flags, DEV sources.
        .target(
            name: "CmuxiOSShell",
            dependencies: ["CmuxiOSDesign", "CmuxiOSFeatureKit", "CmuxiOSPlatform"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxiOSShellTests",
            dependencies: ["CmuxiOSShell", "CmuxiOSFeatureKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // App-wide services: router, toasts, remote flags, diagnostics,
        // What's New, Mac gate, demo mode, keep-awake and billing seams
        // (plans/cmux-next/ios-next/c16-platform.md). No UIKit, so its tests
        // also run on macOS.
        .target(
            name: "CmuxiOSPlatform",
            dependencies: [
                "CmuxiOSFeatureKit",
                .product(name: "CmuxSentryScrubbing", package: "CmuxSentryTelemetry"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxiOSPlatformTests",
            dependencies: ["CmuxiOSPlatform", "CmuxiOSFeatureKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The platform services' screens: toast overlay, diagnostics, What's
        // New, Mac update gate, keep-awake row, plans stub.
        .target(
            name: "CmuxiOSPlatformUI",
            dependencies: ["CmuxiOSPlatform", "CmuxiOSDesign", "CmuxiOSFeatureKit"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Sentry under the shared telemetry consent, scrubbed last-mile.
        .target(
            name: "CmuxiOSCrashReporting",
            dependencies: [
                .product(name: "CmuxSentryReporting", package: "CmuxSentryTelemetry"),
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
