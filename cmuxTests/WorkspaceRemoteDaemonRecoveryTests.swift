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

    /// https://github.com/manaflow-ai/cmux/issues/10640: a non-proxy SSH
    /// failure ("ssh: connect to host …") is logged with source "remote".
    /// Once the transport publishes an authoritative `.connected`, that
    /// recovered failure must not stay pinned as the sidebar row's latest
    /// (red) log entry.
    @Test
    func connectedRetractsRecoveredSSHConnectionError() {
        let workspace = Workspace()
        let target = "dev@example.com"
        let config = WorkspaceRemoteConfiguration(
            destination: target,
            port: 22,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_023,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test-ssh-error.sock",
            terminalStartupCommand: "ssh dev@example.com",
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: true
        )
        workspace.configureRemoteConnection(config, autoConnect: false)

        workspace.applyRemoteConnectionStateUpdate(
            .error,
            detail: "ssh: connect to host example.com port 22: Operation timed out (retry 3 in 8s)",
            target: target
        )

        #expect(workspace.logEntries.last?.source == "remote")
        #expect(workspace.logEntries.last?.level == .error)

        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to \(target)",
            target: target
        )

        #expect(
            workspace.logEntries.last(where: { $0.source == "remote" }) == nil,
            "A recovered SSH connection error must be retracted on .connected"
        )
        #expect(
            workspace.logEntries.last?.level != .error,
            "The workspace row must not keep rendering a recovered SSH error while Connected"
        )
        #expect(workspace.statusEntries["remote.error"] == nil)
    }

    /// https://github.com/manaflow-ai/cmux/issues/10640: the suspended-state
    /// warning ("SSH reconnect paused …", source "remote") must likewise be
    /// retracted once the connection recovers to `.connected`.
    @Test
    func connectedRetractsRecoveredSuspendedWarning() {
        let workspace = Workspace()
        let target = "dev@example.com"
        let config = WorkspaceRemoteConfiguration(
            destination: target,
            port: 22,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_024,
            relayID: String(repeating: "1", count: 16),
            relayToken: String(repeating: "2", count: 64),
            localSocketPath: "/tmp/cmux-debug-test-suspended.sock",
            terminalStartupCommand: "ssh dev@example.com",
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: true
        )
        workspace.configureRemoteConnection(config, autoConnect: false)

        workspace.applyRemoteConnectionStateUpdate(
            .suspended,
            detail: "Reconnect budget exhausted",
            target: target
        )

        #expect(workspace.logEntries.last?.source == "remote")
        #expect(workspace.statusEntries["remote.error"] != nil)

        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to \(target)",
            target: target
        )

        #expect(
            workspace.logEntries.last(where: { $0.source == "remote" }) == nil,
            "A recovered reconnect-paused warning must be retracted on .connected"
        )
        #expect(workspace.statusEntries["remote.error"] == nil)
    }
}
