import CmuxUpdater
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// What an update relaunch would interrupt, counted from workspace agent and shell activity.
@Suite struct UpdateRelaunchBlockersTests {
    @Test func countsMidTurnAgentsAndOtherLocalCommands() {
        let busyAgent = UUID()
        let waitingAgent = UUID()
        let idleAgentShell = UUID()
        let devServer = UUID()
        let idleShell = UUID()
        let local = UpdateRelaunchWorkspaceActivity(
            agentLifecycles: [
                busyAgent: ["claude": .running],
                waitingAgent: ["codex": .needsInput],
                idleAgentShell: ["claude": .idle],
            ],
            shellActivity: [
                busyAgent: .commandRunning,
                waitingAgent: .commandRunning,
                idleAgentShell: .commandRunning,
                devServer: .commandRunning,
                idleShell: .promptIdle,
            ],
            isRemote: false
        )

        let blockers = AppDelegate.updateRelaunchBlockers(workspaces: [local])

        #expect(blockers == UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 1))
    }

    @Test func remoteCommandsDoNotBlockButRemoteAgentsAreWaitedFor() {
        let remote = UpdateRelaunchWorkspaceActivity(
            agentLifecycles: [UUID(): ["claude": .running]],
            shellActivity: [UUID(): .commandRunning],
            isRemote: true
        )

        let blockers = AppDelegate.updateRelaunchBlockers(workspaces: [remote])

        #expect(blockers == UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0))
    }

    @Test func idleWorkspacesDoNotBlock() {
        let idle = UpdateRelaunchWorkspaceActivity(
            agentLifecycles: [UUID(): ["claude": .idle, "codex": .needsInput]],
            shellActivity: [UUID(): .promptIdle],
            isRemote: false
        )

        #expect(AppDelegate.updateRelaunchBlockers(workspaces: [idle]).isEmpty)
    }
}
