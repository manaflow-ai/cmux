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

    /// A reverse-relay bounce publishes a daemon error whose own detail says it
    /// is retrying, and the reconnect state machine always schedules that retry.
    /// Once the daemon reports ready again the workspace is healthy, so the
    /// sidebar must not keep a red row for the outage that already healed.
    @Test
    func recoveredRelayBounceClearsSidebarDaemonError() {
        let workspace = makeRemoteWorkspace()

        for detail in [
            "Remote SSH relay unavailable; retrying in 2 seconds",
            "Remote SSH relay port unavailable; retrying in 2 seconds",
        ] {
            workspace.applyRemoteDaemonStatusUpdate(
                WorkspaceRemoteDaemonStatus(state: .error, detail: detail),
                target: "dev@example.com"
            )
        }

        #expect(
            workspace.logEntries.contains { $0.source == "remote-daemon" && $0.level == .error },
            "The relay bounce should be recorded while the daemon is still down"
        )

        workspace.applyRemoteDaemonStatusUpdate(
            WorkspaceRemoteDaemonStatus(state: .ready),
            target: "dev@example.com"
        )

        #expect(
            workspace.logEntries.contains { $0.source == "remote-daemon" && $0.level == .error } == false,
            "A relay bounce the daemon recovered from must not stay a sidebar error"
        )
    }

    /// The retraction is tied to the daemon actually recovering, so an outage
    /// that never reaches ready keeps its sidebar error.
    @Test
    func daemonErrorWithoutRecoveryKeepsSidebarEntry() {
        let workspace = makeRemoteWorkspace()

        workspace.applyRemoteDaemonStatusUpdate(
            WorkspaceRemoteDaemonStatus(
                state: .error,
                detail: "Remote SSH relay unavailable; retrying in 2 seconds"
            ),
            target: "dev@example.com"
        )
        workspace.applyRemoteDaemonStatusUpdate(
            WorkspaceRemoteDaemonStatus(state: .bootstrapping, detail: "Reconnecting"),
            target: "dev@example.com"
        )

        #expect(
            workspace.logEntries.contains { $0.source == "remote-daemon" && $0.level == .error },
            "An unrecovered daemon outage must keep reporting itself"
        )
    }

    private func makeRemoteWorkspace() -> Workspace {
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
        return workspace
    }
}
