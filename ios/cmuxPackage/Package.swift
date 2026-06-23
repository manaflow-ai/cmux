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
        // CmuxIrohFFI (Rust staticlib C FFI over iroh, Native/cmux-iroh) is
        // linked into the iOS app here so every iOS build proves the xcframework
        // slice matrix; no code references it until the iroh transport lands
        // (plans/feat-ios-iroh/DESIGN.md PR 3). Linked at the app package rather
        // than inside CmuxMobileTransport because a remote-pin-free local
        // dependency does not change a transitive consumer's Package.resolved
        // originHash, which scripts/check-package-resolved-policy.py requires;
        // the app package is the only lockfile-carrying consumer and its
        // originHash does update. PR 3 moves the import into CmuxMobileTransport.
        .package(path: "../../Packages/Shared/CmuxIrohFFI"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(
            name: "cmuxFeature",
            dependencies: [
                // Linked only to prove the iroh xcframework slice matrix; no
                // code imports it yet (see dependencies note above).
                .product(name: "CmuxIrohFFI", package: "CmuxIrohFFI"),
                "CMUXAuthCore",
                "CmuxAuthRuntime",
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
