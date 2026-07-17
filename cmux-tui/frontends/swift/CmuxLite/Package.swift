// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxLite",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxLiteCore", targets: ["CmuxLiteCore"]),
        .executable(name: "cmux-lite", targets: ["CmuxLiteApp"]),
        .executable(name: "cmux-lite-smoke", targets: ["CmuxLiteSmoke"]),
    ],
    targets: [
        .target(
            name: "CmuxLiteCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "CmuxLiteApp",
            dependencies: ["CmuxLiteCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "CmuxLiteSmoke",
            dependencies: ["CmuxLiteCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "CmuxLiteCoreTests",
            dependencies: ["CmuxLiteCore"]
        ),
    ]
)
