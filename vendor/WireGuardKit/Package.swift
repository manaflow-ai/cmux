// swift-tools-version:5.9
// Vendored from wireguard-apple (see README.md in this directory).
//
// WireGuardKit is the Swift adapter between an `NEPacketTunnelProvider` and the
// wireguard-go userspace implementation. The Go half is not built by SwiftPM:
// `WireGuardKitGo` only publishes `wireguard.h` and asks the linker for
// `libwg-go.a`, which the consuming Xcode target produces with
// `scripts/build-wireguard-go.sh` into its BUILT_PRODUCTS_DIR.

import PackageDescription

let package = Package(
    name: "WireGuardKit",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        .library(name: "WireGuardKit", targets: ["WireGuardKit"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WireGuardKit",
            dependencies: ["WireGuardKitGo", "WireGuardKitC"]
        ),
        .target(
            name: "WireGuardKitC",
            dependencies: [],
            publicHeadersPath: "."
        ),
        .target(
            name: "WireGuardKitGo",
            dependencies: [],
            exclude: [
                "go.mod",
                "go.sum",
                "api-apple.go",
            ],
            publicHeadersPath: ".",
            linkerSettings: [.linkedLibrary("wg-go")]
        ),
    ]
)
