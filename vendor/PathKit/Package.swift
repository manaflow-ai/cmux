// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "PathKit",
  products: [
    .library(name: "PathKit", targets: ["PathKit"]),
  ],
  targets: [
    .target(name: "PathKit", dependencies: [], path: "Sources"),
  ]
)
