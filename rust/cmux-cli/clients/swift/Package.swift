// swift-tools-version: 5.9
import PackageDescription

// cmx-swift-client is the Swift-side library that lets the macOS cmux app
// attach to a cmx server. It's integration-ready for the existing cmux
// TerminalPanel type: add a CmxTerminalPanel backend that connects to a
// cmx Unix socket and drives the pane's libghostty-vt instance via Grid
// attach mode (raw PTY bytes streamed from the server).
//
// The actual wire-format encoder/decoder and attach loop are not
// implemented in this commit — the package's source tree only documents
// the contract and provides a scaffold for the integration work. Keeping
// it in-repo means changes to the wire protocol can be shipped in sync
// across crates/cmux-cli-protocol and this package.
let package = Package(
    name: "CmxClient",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CmxClient", targets: ["CmxClient"]),
    ],
    dependencies: [
        // Expected additions once the implementation lands:
        //  .package(url: "https://github.com/Flight-School/MessagePack", from: "1.2.4"),
        //  .package(url: "https://github.com/ghostty-org/ghostty", branch: "main"),
    ],
    targets: [
        .target(
            name: "CmxClient",
            path: "Sources/CmxClient"
        ),
    ]
)
