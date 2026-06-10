@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class WorkspaceRemoteDaemonManifestTests: XCTestCase {
    func testParsesEmbeddedRemoteDaemonManifestJSON() throws {
        let manifestJSON = """
        {
          "schemaVersion": 1,
          "appVersion": "0.62.0",
          "releaseTag": "v0.62.0",
          "releaseURL": "https://github.com/manaflow-ai/cmux/releases/tag/v0.62.0",
          "checksumsAssetName": "cmuxd-remote-checksums.txt",
          "checksumsURL": "https://github.com/manaflow-ai/cmux/releases/download/v0.62.0/cmuxd-remote-checksums.txt",
          "entries": [
            {
              "goOS": "linux",
              "goArch": "amd64",
              "assetName": "cmuxd-remote-linux-amd64",
              "downloadURL": "https://github.com/manaflow-ai/cmux/releases/download/v0.62.0/cmuxd-remote-linux-amd64",
              "sha256": "abc123"
            }
          ]
        }
        """

        let manifest = Workspace.remoteDaemonManifest(from: [
            Workspace.remoteDaemonManifestInfoKey: manifestJSON,
        ])

        XCTAssertEqual(manifest?.releaseTag, "v0.62.0")
        XCTAssertEqual(manifest?.entry(goOS: "linux", goArch: "amd64")?.assetName, "cmuxd-remote-linux-amd64")
    }

    func testRemoteDaemonCachePathIsVersionedByPlatform() throws {
        let url = try Workspace.remoteDaemonCachedBinaryURL(
            version: "0.62.0",
            goOS: "linux",
            goArch: "arm64"
        )

        XCTAssertTrue(url.path.contains("/.local/state/cmux/remote-daemons/0.62.0/linux-arm64/"))
        XCTAssertEqual(url.lastPathComponent, "cmuxd-remote")
    }
}

