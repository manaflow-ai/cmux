import CmuxCore
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceRemoteBadgeTruthTests: XCTestCase {
    @MainActor
    func testPersistentPTYDaemonTransportErrorPropagatesAsError() {
        let workspace = Workspace()
        let config = remoteConfiguration(preserveAfterTerminalExit: true)
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)

        let proxyError = "Remote proxy to host unavailable: Remote daemon transport failed: daemon transport keepalive timed out"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "host")

        XCTAssertEqual(workspace.remoteConnectionState, .error)
        XCTAssertEqual(workspace.remoteConnectionDetail, proxyError)
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, false)
    }

    @MainActor
    func testLegacySSHProxyOnlyErrorStillPreservesConnectedState() {
        let workspace = Workspace()
        let config = remoteConfiguration(preserveAfterTerminalExit: false)
        workspace.configureRemoteConnection(config, autoConnect: false)

        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 1)

        let proxyError = "Remote proxy to host unavailable: Remote daemon transport failed: daemon transport keepalive timed out"
        workspace.applyRemoteConnectionStateUpdate(.error, detail: proxyError, target: "host")

        XCTAssertEqual(workspace.remoteConnectionState, .connected)
        XCTAssertEqual(workspace.remoteConnectionDetail, proxyError)
        XCTAssertEqual(workspace.remoteStatusPayload()["connected"] as? Bool, true)
    }

    private func remoteConfiguration(preserveAfterTerminalExit: Bool) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh-pty-attach",
            preserveAfterTerminalExit: preserveAfterTerminalExit
        )
    }
}
