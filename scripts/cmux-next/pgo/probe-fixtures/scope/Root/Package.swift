// swift-tools-version: 6.2
// Root: asks for the profile, like CmuxNext's app targets.
import PackageDescription

let profdata = Context.environment["CMUX_PGO_PROFDATA"]
let pgo: [SwiftSetting] = profdata.map { [.unsafeFlags(["-profile-use=\($0)"], .when(configuration: .release))] } ?? []

let package = Package(
    name: "Root",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../Mid"), .package(path: "../Dep")],
    targets: [
        .executableTarget(
            name: "RootApp",
            dependencies: [.product(name: "Mid", package: "Mid"), .product(name: "Dep", package: "Dep")],
            swiftSettings: pgo
        ),
    ]
)
