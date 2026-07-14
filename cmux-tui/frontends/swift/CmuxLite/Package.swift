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
    dependencies: [
        .package(
            url: "https://github.com/Lakr233/libghostty-spm.git",
            revision: "faec539df2ada15503da1ff3d5e105b5eadd5264"
        ),
    ],
    targets: [
        .target(
            name: "CmuxLiteCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "CmuxLiteApp",
            dependencies: [
                "CmuxLiteCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
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
