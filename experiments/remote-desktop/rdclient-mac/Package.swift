// swift-tools-version:6.0
// rdclient: macOS measurement client for the rdproto/0 remote desktop prototype.
import PackageDescription

let package = Package(
    name: "rdclient",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "rdclient",
            path: "Sources/rdclient",
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreText"),
            ]
        )
    ]
)
