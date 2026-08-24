import CmuxCore
import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceRemoteDaemonRecoveryTests {
    /// https://github.com/manaflow-ai/cmux/issues/8917: a daemon transport
    /// bounce that re-bootstraps successfully must not leave a permanent error
    /// on the workspace's sidebar row.
    @Test
    func recoveredDaemonTransportBounceClearsSidebarDaemonError() {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 22,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_021,
            relayID: String(repeating: "c", count: 16),
            relayToken: String(repeating: "d", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh dev@example.com",
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: true
        )
        workspace.configureRemoteConnection(config, autoConnect: false)

        workspace.applyRemoteDaemonStatusUpdate(
            WorkspaceRemoteDaemonStatus(state: .ready),
            target: "dev@example.com"
        )
        workspace.applyRemoteDaemonStatusUpdate(
            WorkspaceRemoteDaemonStatus(
                state: .error,
                detail: "Remote daemon transport needs re-bootstrap after proxy failure (retry 1 in 2s)"
            ),
            target: "dev@example.com"
        )

        #expect(workspace.logEntries.last?.level == .error)

        workspace.applyRemoteDaemonStatusUpdate(
            WorkspaceRemoteDaemonStatus(state: .ready),
            target: "dev@example.com"
        )

        #expect(
            workspace.logEntries.last(where: { $0.source == "remote-daemon" }) == nil,
            "A recovered daemon transport bounce must retract its sidebar error"
        )
        #expect(
            workspace.logEntries.last?.level != .error,
            "The workspace row must not keep rendering the recovered daemon error"
        )
    }

    /// A bootstrap failure is published through both the connection-state and
    /// daemon-status seams.  The PTY can subsequently reattach as soon as the
    /// daemon is ready, before a separate proxy `.connected` update arrives.
    /// That recovery ordering must retract the old connection error too.
    @Test
    func daemonReadyClearsBootstrapErrorBeforeProxyConnected() {
        let workspace = Workspace()
        let target = "dev@example.com"
        let config = WorkspaceRemoteConfiguration(
            destination: target,
            port: 22,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_022,
            relayID: String(repeating: "e", count: 16),
            relayToken: String(repeating: "f", count: 64),
            localSocketPath: "/tmp/cmux-debug-test-bootstrap.sock",
            terminalStartupCommand: "ssh dev@example.com",
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: true
        )
        workspace.configureRemoteConnection(config, autoConnect: false)

        let failureDetail =
            "Remote daemon bootstrap failed: remote daemon is not ready (retry 1 in 4s)"
        workspace.applyRemoteConnectionStateUpdate(
            .error,
            detail: failureDetail,
            target: target
        )
        workspace.applyRemoteDaemonStatusUpdate(
            WorkspaceRemoteDaemonStatus(state: .error, detail: failureDetail),
            target: target
        )

        // The reconnect supervisor has started a new attempt; the old error
        // is still the sidebar's latest detail while the proxy comes up.
        workspace.applyRemoteConnectionStateUpdate(
            .reconnecting,
            detail: "Reconnecting to \(target) (retry 1)",
            target: target
        )

        #expect(workspace.statusEntries["remote.error"] != nil)
        #expect(workspace.logEntries.contains { $0.source == "remote-daemon" })

        // The daemon is healthy again, but the proxy/connection presentation
        // has not published `.connected` yet.
        workspace.applyRemoteDaemonStatusUpdate(
            WorkspaceRemoteDaemonStatus(state: .ready),
            target: target
        )

        #expect(
            workspace.statusEntries["remote.error"] == nil,
            "A recovered bootstrap error must not remain in the sidebar"
        )
        #expect(
            workspace.logEntries.last(where: { $0.source == "remote-daemon" }) == nil,
            "A recovered bootstrap log must not remain the sidebar's latest error"
        )
    }
}
