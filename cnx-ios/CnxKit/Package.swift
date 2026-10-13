// swift-tools-version: 6.2

import PackageDescription

// CnxKit: every module of the cnx-ios app. See ../PLAN.md.
let package = Package(
    name: "CnxKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "CnxShell", targets: ["CnxShell"]),
        .library(name: "CnxModel", targets: ["CnxModel"]),
        .library(name: "CnxDesign", targets: ["CnxDesign"]),
        .library(name: "CnxTransport", targets: ["CnxTransport"]),
        .library(name: "CnxMarkdown", targets: ["CnxMarkdown"]),
        .library(name: "CnxDiff", targets: ["CnxDiff"]),
        .library(name: "CnxAgentChat", targets: ["CnxAgentChat"]),
        .library(name: "CnxFeed", targets: ["CnxFeed"]),
        .library(name: "CnxAuth", targets: ["CnxAuth"]),
        .library(name: "CnxOnboarding", targets: ["CnxOnboarding"]),
        .library(name: "CnxSettings", targets: ["CnxSettings"]),
    ],
    dependencies: [
        .package(path: "../../Packages/Shared/CmuxAgentQuestion"),
        // Shared Stack Auth runtime (used as-is; do not modify from here).
        .package(path: "../../Packages/Shared/CmuxAuthRuntime"),
        .package(path: "../../Packages/Shared/CMUXAuthCore"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(name: "CnxDesign"),
        .target(name: "CnxModel"),
        .binaryTarget(name: "CnxFFIFFI", path: "Frameworks/CnxFFI.xcframework"),
        .target(
            name: "CnxFFI",
            dependencies: [.target(name: "CnxFFIFFI", condition: .when(platforms: [.iOS]))],
            path: "Sources/CnxFFI",
            // uniffi's generated Swift is not Swift 6 concurrency-clean.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration")]
        ),
        .target(name: "CnxTransport", dependencies: [.target(name: "CnxFFI", condition: .when(platforms: [.iOS]))]),
        // Markdown: native block renderer for transcripts, WKWebView renderer (pooled) for the Feed and math.
        .target(name: "CnxMarkdown", dependencies: ["CnxDesign"], resources: [.copy("Resources/web")]),
        // Diff model (line + word diff, unified parser) and the GitHub-mobile-style viewer.
        .target(name: "CnxDiff", dependencies: ["CnxDesign"]),
        // ACP agent session model, AgentSessionSource (mock now, acpmux over the link later), chat screen.
        .target(name: "CnxAgentChat", dependencies: [
            "CnxDesign", "CnxModel", "CnxMarkdown", "CnxDiff",
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
        ]),
        .target(name: "CnxFeed", dependencies: [
            "CnxDesign", "CnxModel", "CnxMarkdown", "CnxAgentChat",
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
        ]),
        .target(
            name: "CnxAuth",
            dependencies: [
                "CnxModel",
                .product(name: "CmuxAuthRuntime", package: "CmuxAuthRuntime"),
                .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ]
        ),
        .target(
            name: "CnxOnboarding",
            dependencies: ["CnxDesign", "CnxModel", "CnxAuth"],
            resources: [.process("Resources")]
        ),
        .target(name: "CnxSettings", dependencies: ["CnxDesign", "CnxModel", "CnxAuth"]),
        .target(
            name: "CnxShell",
            dependencies: [
                "CnxDesign", "CnxModel", "CnxAuth", "CnxOnboarding", "CnxSettings",
                "CnxAgentChat", "CnxFeed", "CnxTransport",
            ]
        ),
        .testTarget(name: "CnxModelTests", dependencies: ["CnxModel"]),
        .testTarget(name: "CnxTransportTests", dependencies: ["CnxTransport"]),
        .testTarget(name: "CnxAgentChatTests", dependencies: ["CnxAgentChat", "CnxDiff", "CnxMarkdown"]),
    ],
    swiftLanguageModes: [.v6]
)
