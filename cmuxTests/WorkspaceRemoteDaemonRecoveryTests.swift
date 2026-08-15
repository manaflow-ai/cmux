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
}
