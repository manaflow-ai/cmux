import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A coding agent is one long-lived foreground command, so the shell reports
/// `commandRunning` for the agent's whole lifetime — from `claude` launch until
/// exit. On that signal alone every agent surface confirms on close, including
/// one whose turn finished an hour ago. Closing a surface whose agent is idle
/// or waiting on the user must not confirm; a working agent and every non-agent
/// command still must.
@MainActor
@Suite(.serialized)
struct AgentIdleCloseConfirmationTests {
    private func makeWorkspace(
        agentLifecycle: AgentHibernationLifecycleState?,
        shellActivityState: PanelShellActivityState
    ) throws -> (workspace: Workspace, panelId: UUID) {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        if let agentLifecycle {
            workspace.setAgentLifecycle(
                key: "claude_code",
                panelId: panelId,
                lifecycle: agentLifecycle
            )
        }
        workspace.updatePanelShellActivityState(panelId: panelId, state: shellActivityState)
        return (workspace, panelId)
    }

    @Test
    func idleAgentDoesNotConfirmWhileTheShellStillReportsARunningCommand() throws {
        let (workspace, panelId) = try makeWorkspace(
            agentLifecycle: .idle,
            shellActivityState: .commandRunning
        )
        #expect(
            workspace.panelNeedsConfirmClose(
                panelId: panelId,
                fallbackNeedsConfirmClose: true
            ) == false
        )
    }

    @Test
    func agentWaitingOnTheUserDoesNotConfirm() throws {
        let (workspace, panelId) = try makeWorkspace(
            agentLifecycle: .needsInput,
            shellActivityState: .commandRunning
        )
        #expect(
            workspace.panelNeedsConfirmClose(
                panelId: panelId,
                fallbackNeedsConfirmClose: true
            ) == false
        )
    }

    @Test
    func workingAgentStillConfirms() throws {
        let (workspace, panelId) = try makeWorkspace(
            agentLifecycle: .running,
            shellActivityState: .commandRunning
        )
        #expect(
            workspace.panelNeedsConfirmClose(
                panelId: panelId,
                fallbackNeedsConfirmClose: true
            )
        )
    }

    /// The regression guard for non-agent surfaces: a plain `make` or `rm -rf`
    /// reports no agent lifecycle at all and must keep confirming.
    @Test
    func runningCommandWithNoAgentAttachedStillConfirms() throws {
        let (workspace, panelId) = try makeWorkspace(
            agentLifecycle: nil,
            shellActivityState: .commandRunning
        )
        #expect(
            workspace.panelNeedsConfirmClose(
                panelId: panelId,
                fallbackNeedsConfirmClose: false
            )
        )
    }

    /// Agent lifecycle only ever relaxes the shell signal, never tightens it: a
    /// surface back at its prompt never confirms, whatever the lifecycle says.
    @Test(arguments: AgentHibernationLifecycleState.allCases)
    func idlePromptNeverConfirms(agentLifecycle: AgentHibernationLifecycleState) throws {
        let (workspace, panelId) = try makeWorkspace(
            agentLifecycle: agentLifecycle,
            shellActivityState: .promptIdle
        )
        #expect(
            workspace.panelNeedsConfirmClose(
                panelId: panelId,
                fallbackNeedsConfirmClose: true
            ) == false
        )
    }

    /// With no shell-integration signal the Ghostty fallback still decides, and
    /// an absent agent lifecycle must not override it in either direction.
    @Test(arguments: [true, false])
    func unknownShellStateKeepsTheGhosttyFallback(fallbackNeedsConfirmClose: Bool) throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        #expect(
            workspace.panelNeedsConfirmClose(
                panelId: panelId,
                fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
            ) == fallbackNeedsConfirmClose
        )
    }
}
