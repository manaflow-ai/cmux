import CmuxCore
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the reconnect boundary after a persistent remote PTY wrapper has
/// already moved the presentation state into a retrying phase.
@MainActor
@Suite(.serialized)
struct RemotePTYReconnectLifecycleTests {
    @Test
    func reconnectRestartsControllerWhenPresentationIsConnectingButOwnerIsGone() async throws {
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = ImmediateRemoteSessionFailureRunner()
        let configuration = WorkspaceRemoteConfiguration(
            destination: "tiny@remote-only",
            port: 22,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh tiny@remote-only",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "remote-pty-reconnect-test"
        )

        #expect(workspace.configureRemoteConnection(configuration, autoConnect: false))
        let initialTransition = try #require(workspace.remoteSessionTransitionTask)
        await initialTransition.value
        let panel = try #require(workspace.focusedTerminalPanel)
        #expect(workspace.activeRemoteTerminalSurfaceIds.contains(panel.id))

        // This is the state produced when the persistent wrapper reports its
        // attachment ended after the old controller has been stopped. The
        // published presentation is retrying, but no owner can make progress.
        workspace.remoteSessionController = nil
        workspace.remoteControllerConnectionState = .disconnected
        workspace.remoteConnectionState = .connecting

        #expect(!workspace.reconnectRemoteConnection(surfaceId: panel.id))
        let transition = try #require(workspace.remoteSessionTransitionTask)
        await transition.value
        #expect(workspace.remoteSessionController != nil)

        workspace.disconnectRemoteConnection(clearConfiguration: true)
        await workspace.remoteSessionTransitionTask?.value
        workspace.teardownAllPanels()
    }
}

private struct ImmediateRemoteSessionFailureRunner: RemoteSessionProcessRunning, Sendable {
    func run(
        _: RemoteProcessRequest,
        operation _: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        RemoteCommandResult(status: 1, stdout: "", stderr: "intentional reconnect-test stop")
    }
}
