// swift-tools-version: 6.0
// R-HARNESS probe (never merge): how the journeys' text reader reads the r3-after-switch frames that came back empty.
import PackageDescription

let package = Package(
    name: "OCRProbe",
    platforms: [.macOS(.v14)],
    targets: [
        .testTarget(name: "OCRProbeTests", exclude: ["Fixtures"]),
    ]
)
