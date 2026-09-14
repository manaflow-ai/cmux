import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Restored startup input ownership")
struct RestoredStartupInputOwnershipTests {
    private let selector = " cmux restore codex synthetic-session\n"

    private func awaiting(_ panelId: UUID) -> RestoredAgentLifecycleCoordinator {
        let coordinator = RestoredAgentLifecycleCoordinator()
        coordinator.seedSessionRestore(
            panelId: panelId, snapshot: nil, manualResumeAvailable: false,
            willRunStartupCommand: false, willRunStartupInput: true,
            resumeWorkingDirectory: nil
        )
        coordinator.registerStartupInput(selector, panelId: panelId)
        return coordinator
    }

    @Test("A live agent retires the retry despite a missing shell command-start report",
          arguments: [PanelShellActivityState.promptIdle, .unknown, .commandRunning])
    func liveAgentOwnsInput(shellState: PanelShellActivityState) {
        let panelId = UUID()
        let coordinator = awaiting(panelId)
        #expect(coordinator.armStartupInputResend(panelId: panelId))

        #expect(coordinator.takeStartupInputForResend(
            panelId: panelId, shellState: shellState, hasLiveAgent: true
        ) == nil)
        #expect(coordinator.startupInput(panelId: panelId) == nil)
        #expect(coordinator.resumeStatesByPanelId[panelId] == .autoResumeCommandRunning)
        // Losing process evidence later must not resurrect the consumed retry.
        #expect(!coordinator.armStartupInputResend(panelId: panelId))
        #expect(coordinator.takeStartupInputForResend(
            panelId: panelId, shellState: .promptIdle, hasLiveAgent: false
        ) == nil)
    }

    @Test("A slow shell with no live agent still receives exactly one retry")
    func lostTypeaheadStillRetries() {
        let panelId = UUID()
        let coordinator = awaiting(panelId)
        #expect(coordinator.armStartupInputResend(panelId: panelId))
        #expect(coordinator.takeStartupInputForResend(
            panelId: panelId, shellState: .promptIdle, hasLiveAgent: false
        ) == selector)
        #expect(coordinator.takeStartupInputForResend(
            panelId: panelId, shellState: .promptIdle, hasLiveAgent: false
        ) == nil)
    }

    @Test("A non-idle shell without live evidence retains input for a later prompt",
          arguments: [PanelShellActivityState.unknown, .commandRunning])
    func nonIdleRetainsInput(shellState: PanelShellActivityState) {
        let panelId = UUID()
        let coordinator = awaiting(panelId)
        #expect(coordinator.takeStartupInputForResend(
            panelId: panelId, shellState: shellState, hasLiveAgent: false
        ) == nil)
        #expect(coordinator.startupInput(panelId: panelId) == selector)
        #expect(coordinator.takeStartupInputForResend(
            panelId: panelId, shellState: .promptIdle, hasLiveAgent: false
        ) == selector)
    }

    @Test("Retiring one panel's retry leaves another panel's retry intact")
    func panelIsolation() {
        let panelId = UUID()
        let other = UUID()
        let coordinator = awaiting(panelId)
        coordinator.seedTransferredState(
            panelId: other, snapshot: nil, resumeState: .awaitingAutoResumeCommand,
            completedGeneration: nil, resumeWorkingDirectory: nil, startupInput: selector
        )
        #expect(coordinator.takeStartupInputForResend(
            panelId: panelId, shellState: .promptIdle, hasLiveAgent: true
        ) == nil)
        #expect(coordinator.takeStartupInputForResend(
            panelId: other, shellState: .promptIdle, hasLiveAgent: false
        ) == selector)
    }

    @Test("Live evidence cannot revive an abandoned restore")
    func abandonedRestoreStaysCleared() {
        let panelId = UUID()
        let coordinator = awaiting(panelId)
        coordinator.clearSessionRestore(panelId: panelId)
        #expect(coordinator.takeStartupInputForResend(
            panelId: panelId, shellState: .promptIdle, hasLiveAgent: true
        ) == nil)
        #expect(coordinator.resumeStatesByPanelId[panelId] == nil)
    }

    @Test("A transferred pending retry is retired when the new owner observes the agent")
    func transferredRetryRespectsLiveness() {
        let panelId = UUID()
        let coordinator = RestoredAgentLifecycleCoordinator()
        coordinator.seedTransferredState(
            panelId: panelId, snapshot: nil, resumeState: .awaitingAutoResumeCommand,
            completedGeneration: nil, resumeWorkingDirectory: nil, startupInput: selector
        )
        #expect(coordinator.takeStartupInputForResend(
            panelId: panelId, shellState: .promptIdle, hasLiveAgent: true
        ) == nil)
        #expect(!coordinator.awaitsStartupInput(panelId: panelId))
        #expect(coordinator.resumeStatesByPanelId[panelId] == .autoResumeCommandRunning)
    }
}
