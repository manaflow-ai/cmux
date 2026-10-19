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
        .library(name: "CnxWorkspaces", targets: ["CnxWorkspaces"]),
        .library(name: "CnxChief", targets: ["CnxChief"]),
        .library(name: "CnxTerminal", targets: ["CnxTerminal"]),
        .library(name: "CnxLive", targets: ["CnxLive"]),
        .library(name: "CnxArtifacts", targets: ["CnxArtifacts"]),
        .library(name: "CnxBrowserStream", targets: ["CnxBrowserStream"]),
    ],
    dependencies: [
        .package(path: "../../Packages/Shared/CmuxGhosttyKit"),
        .package(path: "../../Packages/Shared/CmuxAgentQuestion"),
        // Shared Stack Auth runtime (used as-is; do not modify from here).
        .package(path: "../../Packages/Shared/CmuxAuthRuntime"),
        .package(path: "../../Packages/Shared/CMUXAuthCore"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
        // Safari-style tabs (workspaces) and the Messages-style conversation (Chief).
        .package(path: "../../Packages/iOS/CmuxTabsKit"),
        .package(path: "../../Packages/iOS/CmuxConversation"),
        // The agents' brand marks (Claude, Codex), shared with the Mac app.
        .package(path: "../../Packages/Shared/CmuxAgentBrands"),
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
        // Session artifacts: the reference model and extractor, sources (mock, inline, the Mac's `file`
        // link service), the browser and previews. Shared by the terminal and agent sessions.
        .target(name: "CnxArtifacts", dependencies: ["CnxDesign", "CnxTransport"]),
        // ACP agent session model, AgentSessionSource (mock now, acpmux over the link later), chat screen.
        .target(name: "CnxAgentChat", dependencies: [
            "CnxDesign", "CnxModel", "CnxMarkdown", "CnxDiff", "CnxArtifacts", "CnxTransport",
            .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
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
        .target(name: "CnxSettings", dependencies: ["CnxDesign", "CnxModel", "CnxAuth", "CnxOnboarding"]),
        // Streamed browser tabs: a Mac browser page as H.264 video over the link's
        // `browser` service (VideoToolbox decode, rb input, rb.page chrome).
        .target(name: "CnxBrowserStream", dependencies: ["CnxDesign", "CnxTransport"]),
        // Workspaces list and the per-workspace TabsKit navigation (last tab first).
        .target(name: "CnxWorkspaces", dependencies: [
            "CnxDesign", "CnxModel", "CnxAgentChat", "CnxBrowserStream",
            .product(name: "CmuxTabsKit", package: "CmuxTabsKit"),
        ]),
        // Home: the Messages-style conversation list and the Chief chat over CmuxConversation.
        .target(name: "CnxChief", dependencies: [
            "CnxDesign", "CnxModel", "CnxTransport", "CnxAgentChat",
            .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxConversationCore", package: "CmuxConversation"),
            .product(name: "CmuxConversationUI", package: "CmuxConversation", condition: .when(platforms: [.iOS])),
        ]),
        // Live data: device registry, presence, the Mac link state machine, the
        // daemon tree, acpmux chats, Feed events and Chief over the link.
        .target(name: "CnxLive", dependencies: [
            "CnxDesign", "CnxModel", "CnxTransport", "CnxAgentChat", "CnxArtifacts", "CnxFeed", "CnxChief", "CnxTerminal",
            "CnxBrowserStream",
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
        ]),
        .target(
            name: "CnxTerminal",
            // libghostty ships for iOS only here; macOS `swift test` builds the
            // portable parts (session, detector, extractor, input) without it.
            dependencies: ["CnxDesign", "CnxArtifacts", "CnxTransport", .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit", condition: .when(platforms: [.iOS]))]
        ),
        .target(
            name: "CnxShell",
            dependencies: [
                "CnxDesign", "CnxModel", "CnxAuth", "CnxOnboarding", "CnxSettings",
                "CnxAgentChat", "CnxFeed", "CnxTransport", "CnxWorkspaces", "CnxChief", "CnxLive", "CnxTerminal",
                "CnxBrowserStream",
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            ]
        ),
        .testTarget(name: "CnxModelTests", dependencies: ["CnxModel"]),
        .testTarget(name: "CnxTransportTests", dependencies: ["CnxTransport"]),
        .testTarget(name: "CnxAgentChatTests", dependencies: ["CnxAgentChat", "CnxDiff", "CnxMarkdown", "CnxArtifacts"]),
        .testTarget(name: "CnxTerminalTests", dependencies: ["CnxTerminal"]),
        .testTarget(name: "CnxBrowserStreamTests", dependencies: ["CnxBrowserStream", "CnxTransport"]),
        .testTarget(name: "CnxWorkspacesTests", dependencies: ["CnxWorkspaces", "CnxModel", "CnxAgentChat"]),
        .testTarget(name: "CnxLiveTests", dependencies: [
            "CnxLive", "CnxTransport", "CnxModel", "CnxAgentChat", "CnxFeed", "CnxTerminal", "CnxDesign",
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
        ]),
        .testTarget(name: "CnxShellTests", dependencies: ["CnxShell"]),
        .testTarget(name: "CnxOnboardingTests", dependencies: ["CnxOnboarding"]),
        .testTarget(name: "CnxChiefTests", dependencies: [
            "CnxChief", "CnxTransport", "CnxModel", "CnxAgentChat",
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxConversationCore", package: "CmuxConversation"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
