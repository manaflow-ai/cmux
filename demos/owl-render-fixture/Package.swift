// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OwlRenderFixture",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "OwlBrowserCore",
            targets: ["OwlBrowserCore"]
        ),
        .executable(
            name: "OwlLayerHostVerifier",
            targets: ["OwlLayerHostVerifier"]
        ),
        .executable(
            name: "OwlMojoBindingsGenerator",
            targets: ["OwlMojoBindingsGenerator"]
        ),
        .executable(
            name: "OwlLayerHostSelfTest",
            targets: ["OwlLayerHostSelfTest"]
        )
    ],
    targets: [
        .target(
            name: "OwlMojoBindingsGeneratorCore",
            path: "Sources/OwlMojoBindingsGeneratorCore"
        ),
        .target(
            name: "OwlMojoBindingsGenerated",
            path: "Sources/OwlMojoBindingsGenerated"
        ),
        .target(
            name: "OwlBrowserCore",
            dependencies: ["OwlMojoBindingsGenerated"],
            path: "Sources/OwlBrowserCore"
        ),
        .executableTarget(
            name: "OwlMojoBindingsGenerator",
            dependencies: ["OwlMojoBindingsGeneratorCore"],
            path: "Sources/OwlMojoBindingsGenerator"
        ),
        .executableTarget(
            name: "OwlLayerHostVerifier",
            dependencies: [
                "OwlBrowserCore",
                "OwlMojoBindingsGenerated",
            ],
            path: "Sources/OwlLayerHostVerifier"
        ),
        .executableTarget(
            name: "OwlLayerHostSelfTest",
            path: "Sources/OwlLayerHostSelfTest"
        ),
        .testTarget(
            name: "OwlMojoBindingsGeneratorTests",
            dependencies: [
                "OwlMojoBindingsGenerated",
                "OwlMojoBindingsGeneratorCore",
            ],
            path: "Tests/OwlMojoBindingsGeneratorTests"
        ),
        .testTarget(
            name: "OwlBrowserCoreTests",
            dependencies: [
                "OwlBrowserCore",
                "OwlMojoBindingsGenerated",
            ],
            path: "Tests/OwlBrowserCoreTests"
        )
    ]
)
