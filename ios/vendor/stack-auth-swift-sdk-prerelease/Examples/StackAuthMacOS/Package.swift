// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StackAuthMacOS",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(name: "StackAuth", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "StackAuthMacOS",
            dependencies: [
                .product(name: "StackAuth", package: "StackAuth")
            ],
            path: "StackAuthMacOS"
        )
    ]
)
