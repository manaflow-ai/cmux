import CmuxUpdater
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// What an update relaunch would interrupt, classified per agent from panel agent and shell
/// activity.
@Suite struct UpdateRelaunchBlockersTests {
    private func panel(
        _ agents: [String: AgentHibernationLifecycleState] = [:],
        shell: PanelShellActivityState? = nil,
        remote: Bool = false
    ) -> UpdateRelaunchPanelActivity {
        UpdateRelaunchPanelActivity(
            panelId: UUID(),
            location: "work",
            agentLifecycles: agents,
            shellActivity: shell,
            isRemote: remote
        )
    }

    private func safeties(_ blockers: UpdateRelaunchBlockers) -> [UpdateResumeSafety] {
        blockers.agents.map(\.safety)
    }

    @Test func classifiesLocalAgentsAndCountsOtherLocalCommands() {
        let blockers = AppDelegate.updateRelaunchBlockers(panels: [
            panel(["claude_code": .running], shell: .commandRunning),
            panel(["codex": .needsInput], shell: .commandRunning),
            panel(["claude_code": .idle], shell: .commandRunning),
            panel(shell: .commandRunning),
            panel(shell: .promptIdle),
            panel(),
        ])

        #expect(safeties(blockers) == [.risky, .risky, .safe])
        #expect(blockers.agents.map(\.name) == ["Claude Code", "Codex", "Claude Code"])
        #expect(blockers.runningCommandCount == 1)
        #expect(blockers.needsConfirmation)
    }

    @Test func pendingPermissionIsRiskyEvenWhileTheAgentReportsRunning() {
        let blockers = AppDelegate.updateRelaunchBlockers(panels: [
            panel(["claude_code": .running, "cmux.feed.attention:claude_code": .needsInput]),
        ])

        #expect(safeties(blockers) == [.risky])
        #expect(blockers.agents.first?.name == "Claude Code")
        #expect(blockers.agents.first?.activity == "Waiting for your answer")
    }

    @Test func remoteAgentsKeepRunningSoTheyAreSafeAndRemoteCommandsDoNotCount() {
        let blockers = AppDelegate.updateRelaunchBlockers(panels: [
            panel(["claude_code": .running], remote: true),
            panel(shell: .commandRunning, remote: true),
        ])

        #expect(safeties(blockers) == [.safe])
        #expect(blockers.runningCommandCount == 0)
        #expect(!blockers.needsConfirmation)
    }

    @Test func manualLoadingKeysAreNotAgents() {
        let blockers = AppDelegate.updateRelaunchBlockers(panels: [
            panel([AgentHibernationLifecycleStatusKeys.manualKey: .running], shell: .commandRunning),
        ])

        #expect(blockers.agents.isEmpty)
        #expect(blockers.runningCommandCount == 1)
    }
}
