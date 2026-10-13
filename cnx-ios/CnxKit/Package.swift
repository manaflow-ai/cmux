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
        .target(name: "CnxShell", dependencies: ["CnxDesign", "CnxModel", "CnxTransport"]),
        .testTarget(name: "CnxModelTests", dependencies: ["CnxModel"]),
        .testTarget(name: "CnxTransportTests", dependencies: ["CnxTransport"]),
    ],
    swiftLanguageModes: [.v6]
)
