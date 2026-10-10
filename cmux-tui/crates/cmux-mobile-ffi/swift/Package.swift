// swift-tools-version: 5.10
// Test harness for the generated Swift bindings of cmux-mobile-ffi.
// .github/workflows/cmux-mobile-ffi.yml writes build/CmuxMobileFFIFFI.xcframework
// and Sources/CmuxMobileFFI/CmuxMobileFFI.swift (both gitignored) before it
// runs `swift test` and the iOS simulator tests. Apps consume the published
// xcframework from slice 1 on; nothing links this package.
import PackageDescription

let package = Package(
    name: "CmuxMobileFFI",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "CmuxMobileFFI", targets: ["CmuxMobileFFI"])],
    targets: [
        .binaryTarget(name: "CmuxMobileFFIFFI", path: "build/CmuxMobileFFIFFI.xcframework"),
        .target(name: "CmuxMobileFFI", dependencies: ["CmuxMobileFFIFFI"]),
        .testTarget(name: "CmuxMobileFFITests", dependencies: ["CmuxMobileFFI"]),
    ]
)
