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
        .library(name: "CnxTerminal", targets: ["CnxTerminal"]),
    ],
    dependencies: [
        .package(path: "../../Packages/Shared/CmuxGhosttyKit"),
    ],
    targets: [
        .target(name: "CnxDesign"),
        .target(name: "CnxModel"),
        .target(
            name: "CnxTerminal",
            dependencies: ["CnxDesign", .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit")]
        ),
        .target(name: "CnxShell", dependencies: ["CnxDesign", "CnxModel", "CnxTerminal"]),
        .testTarget(name: "CnxModelTests", dependencies: ["CnxModel"]),
        .testTarget(name: "CnxTerminalTests", dependencies: ["CnxTerminal"]),
    ],
    swiftLanguageModes: [.v6]
)
