// swift-tools-version: 6.0
// Spike (not for landing): keep the acpmux LocalApp token out of the agent pane's page world.
// Design A (isolated content world) and design B (native-side transport), with a bench.
// See /tmp/pane-protocol/localapp-isolation-spike.md.
import PackageDescription

let package = Package(
    name: "LocalAppSpike",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "LocalAppSpike", resources: [.copy("JS")]),
        .testTarget(name: "LocalAppSpikeTests", dependencies: ["LocalAppSpike"]),
    ],
    swiftLanguageModes: [.v5]
)
