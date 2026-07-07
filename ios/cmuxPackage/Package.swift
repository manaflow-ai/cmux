// swift-tools-version: 6.0

import PackageDescription

// `cmuxFeature` is the iOS composition-root package, not a catch-all. After the
// 5079 refactor it holds only the runtime DI bundle (`CMUXMobileRuntime`), the
// auth composition (`MobileAuthComposition` over `CmuxAuthRuntime`), and the
// root scene (`CMUXMobileRootScene`). The store, RPC, persistence, terminal,
// and view code were lifted into the focused packages it depends on below. See
// README.md for the per-type role table.
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
        .package(path: "../../Packages/Shared/CMUXAuthCore"),
        .package(path: "../../Packages/Shared/CmuxAuthRuntime"),
        .package(path: "../../Packages/Shared/CmuxClientConfig"),
        .package(path: "../../Packages/Shared/CMUXMobileCore"),
        .package(path: "../../Packages/iOS/CmuxMobileAnalytics"),
        .package(path: "../../Packages/iOS/CmuxMobileBrowser"),
        .package(path: "../../Packages/iOS/CmuxMobileCamera"),
        .package(path: "../../Packages/iOS/CmuxMobileDiagnostics"),
        .package(path: "../../Packages/iOS/CmuxMobilePairedMac"),
        .package(path: "../../Packages/iOS/CmuxMobileRPC"),
        .package(path: "../../Packages/iOS/CmuxMobileShell"),
        .package(path: "../../Packages/iOS/CmuxMobileShellModel"),
        .package(path: "../../Packages/iOS/CmuxMobileShellUI"),
        .package(path: "../../Packages/iOS/CmuxMobileSupport"),
        .package(path: "../../Packages/iOS/CmuxMobileTerminal"),
        .package(path: "../../Packages/iOS/CmuxMobileTerminalKit"),
        .package(path: "../../Packages/iOS/CmuxMobileTransport"),
        .package(path: "../../Packages/iOS/CmuxMobileWorkspace"),
        // CmuxMobileIrohTransport (iroh dial + accept lanes over CmuxIrohFFI) is
        // linked into the iOS app so cmuxApp can register the .iroh transport; it
        // pulls CmuxIrohFFI transitively, proving the xcframework slice matrix.
        // It lives in Packages/Shared, not inside CmuxMobileTransport, because a
        // remote-pin-free local dependency does not change a transitive
        // consumer's Package.resolved originHash, which
        // scripts/check-package-resolved-policy.py requires; the app package is
        // the only lockfile-carrying consumer and its originHash does update.
        .package(path: "../../Packages/Shared/CmuxMobileIrohTransport"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(
            name: "cmuxFeature",
            dependencies: [
                // Pulls CmuxMobileIrohTransport (and CmuxIrohFFI transitively)
                // into the iOS app's package graph so cmuxApp can register the
                // .iroh transport; cmuxFeature itself does not import it.
                .product(name: "CmuxMobileIrohTransport", package: "CmuxMobileIrohTransport"),
                "CMUXAuthCore",
                "CmuxAuthRuntime",
                "CmuxClientConfig",
                "CMUXMobileCore",
                "CmuxMobileAnalytics",
                "CmuxMobileBrowser",
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
                "CmuxClientConfig",
                "CMUXMobileCore",
                "CmuxMobileAnalytics",
                "CmuxMobileBrowser",
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
