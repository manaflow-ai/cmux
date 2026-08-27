import CmuxSettings
import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Implicit socket discovery may reroute a CLI whose own default socket is
/// dead to another live cmux socket, and it says so on stderr. That notice
/// belongs to the connection, not to argument parsing: a command that never
/// opens the socket must stay silent, or `--json` consumers that merge stderr
/// (and the app-host CI, whose isolated app host is always such a live
/// fallback) get a non-JSON line in front of the payload.
final class CLISocketRerouteNoticeTests: XCTestCase {
    private let support = CLINotifyProcessIntegrationRegressionTests(invocation: nil)

    func testSocketFreeCommandStaysSilentAndSocketCommandAnnouncesReroute() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: Self.self)
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-reroute-notice-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        // A live mock socket that implicit discovery can find through the
        // dev-variant marker file, while the variant's own default socket
        // (a fresh tag slug) does not exist.
        let slug = "reroute-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let socketPath = support.makeSocketPath("reroute")
        let listenerFD = try support.bindUnixSocket(at: socketPath)
        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let state = CLINotifyProcessIntegrationRegressionTests.MockSocketServerState()
        support.startDetachedMockServer(listenerFD: listenerFD, state: state) { _ in "PONG" }

        let environment = [
            "HOME": root.path,
            "CFFIXED_USER_HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_TAG": slug,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        let variant = SocketPathMarkerFiles.variant(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: environment
        )
        let markerPath = variant.tmpPath
        let previousMarker = try? Data(contentsOf: URL(fileURLWithPath: markerPath))
        try Data(socketPath.utf8).write(to: URL(fileURLWithPath: markerPath), options: .atomic)
        defer {
            if let previousMarker {
                try? previousMarker.write(to: URL(fileURLWithPath: markerPath), options: .atomic)
            } else {
                unlink(markerPath)
            }
        }

        let themes = support.runProcess(
            executablePath: cliPath,
            arguments: ["--json", "themes", "list"],
            environment: environment,
            timeout: 10
        )
        XCTAssertFalse(themes.timedOut, themes.stderr)
        XCTAssertEqual(themes.status, 0, themes.stderr)
        XCTAssertEqual(
            themes.stderr,
            "",
            "a command that never opens the socket must not announce a reroute"
        )
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: Data(themes.stdout.utf8)),
            "themes list --json must stay parseable: \(themes.stdout.prefix(200))"
        )
        XCTAssertTrue(state.snapshot().isEmpty, "themes list must not open the socket: \(state.snapshot())")

        let ping = support.runProcess(
            executablePath: cliPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 10
        )
        XCTAssertFalse(ping.timedOut, ping.stderr)
        XCTAssertEqual(ping.status, 0, ping.stderr)
        XCTAssertTrue(
            ping.stderr.contains("cmux: default socket"),
            "a command that connects through a rerouted socket must announce it: \(ping.stderr)"
        )
        XCTAssertTrue(state.snapshot().contains("ping"), "ping must reach the rerouted socket: \(state.snapshot())")
    }
}
