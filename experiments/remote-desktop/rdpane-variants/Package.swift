// swift-tools-version:6.0
// rdpane-variants: throwaway UI prototype for the remote desktop pane and the
// host indicator. Draws a synthetic remote desktop; no capture, no network.
import Foundation
import PackageDescription

// A bare executable has no main bundle localizations, and CFBundle limits a
// resource bundle's language to the main bundle's. Embedding an Info.plist
// that lists en and ja lets `-AppleLanguages (ja)` select Japanese.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Support/Info.plist").path

let package = Package(
    name: "rdpane-variants",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "rdpane-variants",
            path: "Sources/rdpane-variants",
            resources: [.process("Resources")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])
            ]
        )
    ]
)
