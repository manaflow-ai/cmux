// swift-tools-version: 6.2
// Dep: a package that does not ask, like Sentry or Sparkle.
import PackageDescription

let package = Package(
    name: "Dep",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Dep", targets: ["Dep"])],
    targets: [.target(name: "Dep")]
)
