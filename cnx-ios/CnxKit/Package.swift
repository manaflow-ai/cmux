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
    ],
    targets: [
        .target(name: "CnxDesign"),
        .target(name: "CnxModel"),
        .target(name: "CnxShell", dependencies: ["CnxDesign", "CnxModel"]),
        .testTarget(name: "CnxModelTests", dependencies: ["CnxModel"]),
    ],
    swiftLanguageModes: [.v6]
)
