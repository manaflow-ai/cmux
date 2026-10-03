import CmuxUpdater
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// What an update relaunch would interrupt, counted from panel agent and shell activity.
@Suite struct UpdateRelaunchBlockersTests {
    private func panel(
        _ agents: [String: AgentHibernationLifecycleState] = [:],
        shell: PanelShellActivityState? = nil,
        remote: Bool = false
    ) -> UpdateRelaunchPanelActivity {
        UpdateRelaunchPanelActivity(agentLifecycles: agents, shellActivity: shell, isRemote: remote)
    }

    @Test func countsMidTurnAgentsAndOtherLocalCommands() {
        let blockers = AppDelegate.updateRelaunchBlockers(panels: [
            panel(["claude": .running], shell: .commandRunning),
            panel(["codex": .needsInput], shell: .commandRunning),
            panel(["claude": .idle], shell: .commandRunning),
            panel(shell: .commandRunning),
            panel(shell: .promptIdle),
            panel(),
        ])

        #expect(blockers == UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 1))
    }

    @Test func remoteCommandsDoNotBlockButRemoteAgentsAreWaitedFor() {
        let blockers = AppDelegate.updateRelaunchBlockers(panels: [
            panel(["claude": .running], remote: true),
            panel(shell: .commandRunning, remote: true),
        ])

        #expect(blockers == UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0))
    }

    @Test func manualLoadingKeysAreNotAgents() {
        let blockers = AppDelegate.updateRelaunchBlockers(panels: [
            panel([AgentHibernationLifecycleStatusKeys.manualKey: .running], shell: .commandRunning),
        ])

        #expect(blockers == UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 1))
    }
}
