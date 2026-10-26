// swift-tools-version: 6.2
// Mid: a local path package that asks, like CmuxNext as cmux.xcodeproj's local package reference.
import PackageDescription

let profdata = Context.environment["CMUX_PGO_PROFDATA"]
let pgo: [SwiftSetting] = profdata.map { [.unsafeFlags(["-profile-use=\($0)"], .when(configuration: .release))] } ?? []

let package = Package(
    name: "Mid",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Mid", targets: ["Mid"])],
    targets: [.target(name: "Mid", swiftSettings: pgo)]
)
