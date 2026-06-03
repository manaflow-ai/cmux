import XCTest
@testable import cmux_DEV

final class TerminalRemoteDaemonBootstrapTests: XCTestCase {
    func testBundledDaemonPathPrefersExactPlatformMatch() throws {
        let fixtureRoot = try makeFixtureRoot()
        let locator = TerminalRemoteDaemonBootstrap.BundleLocator(resourceRoot: fixtureRoot)

        let url = try locator.binaryURL(goOS: "linux", goArch: "arm64", version: "dev")

        XCTAssertEqual(url.lastPathComponent, "cmuxd-remote")
        XCTAssertTrue(url.path.contains("/cmuxd-remote/dev/linux-arm64/"))
    }

    func testRemotePlatformProbeParsesUnameOutput() throws {
        let platform = try TerminalRemoteDaemonBootstrap.parsePlatform(stdout: "Linux\nx86_64\n")

        XCTAssertEqual(platform.goOS, "linux")
        XCTAssertEqual(platform.goArch, "amd64")
    }

    func testInstallScriptEncodesBundledBinaryWithoutScp() throws {
        let script = try TerminalRemoteDaemonBootstrap.installScript(
            remotePath: "~/.cmux/bin/cmuxd-remote/dev/linux-arm64/cmuxd-remote"
        )

        XCTAssertTrue(script.contains("base64"))
        XCTAssertTrue(script.contains("chmod 755"))
        XCTAssertTrue(script.contains("~/.cmux/bin/cmuxd-remote/dev/linux-arm64/cmuxd-remote"))
        XCTAssertTrue(script.contains("set -eu"))
        XCTAssertFalse(script.contains("pipefail"))
        XCTAssertFalse(script.contains("QUJD"))
    }

    private func makeFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let binaryDirectory = root
            .appendingPathComponent("cmuxd-remote", isDirectory: true)
            .appendingPathComponent("dev", isDirectory: true)
            .appendingPathComponent("linux-arm64", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let binaryURL = binaryDirectory.appendingPathComponent("cmuxd-remote", isDirectory: false)
        FileManager.default.createFile(atPath: binaryURL.path, contents: Data(), attributes: nil)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
