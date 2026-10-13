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
        .library(name: "CnxAuth", targets: ["CnxAuth"]),
        .library(name: "CnxOnboarding", targets: ["CnxOnboarding"]),
        .library(name: "CnxSettings", targets: ["CnxSettings"]),
    ],
    dependencies: [
        // Shared Stack Auth runtime (used as-is; do not modify from here).
        .package(path: "../../Packages/Shared/CmuxAuthRuntime"),
        .package(path: "../../Packages/Shared/CMUXAuthCore"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(name: "CnxDesign"),
        .target(name: "CnxModel"),
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
            dependencies: ["CnxDesign", "CnxModel", "CnxAuth", "CnxOnboarding", "CnxSettings"]
        ),
        .testTarget(name: "CnxModelTests", dependencies: ["CnxModel"]),
    ],
    swiftLanguageModes: [.v6]
)
