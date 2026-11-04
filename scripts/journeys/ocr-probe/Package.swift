// swift-tools-version: 6.0
// R-HARNESS probe (never merge): the journeys' text reader, base and fixed, on the stored r3-after-switch frames.
import PackageDescription

let package = Package(
    name: "OCRProbe",
    platforms: [.macOS(.v14)],
    targets: [
        .testTarget(name: "OCRProbeTests", exclude: ["Corpus", "Tools"]),
    ]
)
