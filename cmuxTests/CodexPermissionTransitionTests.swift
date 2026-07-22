import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Codex permission transitions")
struct CodexPermissionTransitionTests {
    private let runtime = CodexPermissionRuntimeGeneration(
        pid: 4_242,
        pidStartSeconds: 10,
        pidStartMicroseconds: 20
    )

    @Test func resumedTombstoneRejectsReorderedPermissionForSameRequest() {
        let identity = CodexPermissionSignalIdentity(turnID: "turn-1", requestID: "call-1")
        let resumed = CodexPermissionTransitionMachine.reduce(
            current: nil,
            phase: .resumed,
            identity: identity,
            runtime: runtime
        )
        let reorderedPermission = CodexPermissionTransitionMachine.reduce(
            current: resumed.state,
            phase: .needsInput,
            identity: identity,
            runtime: runtime
        )

        #expect(resumed.accepted)
        #expect(resumed.effect == .none)
        #expect(reorderedPermission.accepted == false)
        #expect(reorderedPermission.state == resumed.state)
    }

    @Test func newerRequestCanFollowAResolvedRequestInTheSameTurn() {
        let resolved = CodexPermissionState(
            phase: .resumed,
            identity: CodexPermissionSignalIdentity(turnID: "turn-1", requestID: "call-1"),
            runtime: runtime
        )
        let newerPermission = CodexPermissionTransitionMachine.reduce(
            current: resolved,
            phase: .needsInput,
            identity: CodexPermissionSignalIdentity(turnID: "turn-1", requestID: "call-2"),
            runtime: runtime
        )

        #expect(newerPermission.accepted)
        #expect(newerPermission.effect == .projectNeedsInput)
        #expect(newerPermission.state.identity.requestID == "call-2")
    }

    @Test func onlyTheExactPendingRequestCanResolveNeedsInput() {
        let pending = CodexPermissionState(
            phase: .needsInput,
            identity: CodexPermissionSignalIdentity(turnID: "turn-2", requestID: "call-new"),
            runtime: runtime
        )
        let staleScopedResume = CodexPermissionTransitionMachine.reduce(
            current: pending,
            phase: .resumed,
            identity: CodexPermissionSignalIdentity(turnID: "turn-2", requestID: "call-old"),
            runtime: runtime
        )
        let unscopedResume = CodexPermissionTransitionMachine.reduce(
            current: pending,
            phase: .resumed,
            identity: CodexPermissionSignalIdentity(turnID: nil, requestID: nil),
            runtime: runtime
        )
        let exactResume = CodexPermissionTransitionMachine.reduce(
            current: pending,
            phase: .resumed,
            identity: pending.identity,
            runtime: runtime
        )

        #expect(staleScopedResume.accepted == false)
        #expect(unscopedResume.accepted == false)
        #expect(exactResume.accepted)
        #expect(exactResume.effect == .resolveNeedsInput)
    }

    @Test func aDifferentRuntimeGenerationCannotResolveThePrompt() {
        let pending = CodexPermissionState(
            phase: .needsInput,
            identity: CodexPermissionSignalIdentity(turnID: "turn-1", requestID: "call-1"),
            runtime: runtime
        )
        let reusedPID = CodexPermissionRuntimeGeneration(
            pid: runtime.pid,
            pidStartSeconds: 99,
            pidStartMicroseconds: 1
        )
        let transition = CodexPermissionTransitionMachine.reduce(
            current: pending,
            phase: .resumed,
            identity: pending.identity,
            runtime: reusedPID
        )

        #expect(transition.accepted == false)
        #expect(transition.state == pending)
    }
}

@Suite("Agent status reconciliation scheduling")
struct AgentStatusReconciliationSchedulingTests {
    @Test @MainActor func emptySweepStillThrottlesTheProcessWideCycle() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let coordinator = AgentStatusReconciliationCoordinator { _, _ in [:] }
        let cycleStart = ContinuousClock.now

        #expect(coordinator.reconcile(tabManagers: [manager], at: cycleStart) == nil)
        workspace.recordAgentPID(
            key: "codex.current",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }

        #expect(
            coordinator.reconcile(tabManagers: [manager], at: cycleStart) == nil,
            "An empty sample must still consume the shared reconciliation interval"
        )
    }
}

extension AgentNotificationRegressionTests {
    @Test("Accepted Codex resume clears its panel notification with the lifecycle")
    @MainActor
    func acceptedCodexResumeClearsOnlyItsPendingPanelNotification() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        fixture.source.setAgentLifecycle(
            key: "codex",
            panelId: fixture.panelId,
            lifecycle: .needsInput
        )
        fixture.store.addNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Codex",
            subtitle: "Needs approval",
            body: "Approve this tool"
        )
        #expect(fixture.store.notifications.count == 1)

        let bus = TerminalMutationBus.shared
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }
        TerminalController.shared.controlSidebarScheduleAgentLifecycle(
            target: .workspace(fixture.source.id),
            key: "codex",
            lifecycleRawValue: AgentHibernationLifecycleState.running.rawValue,
            panelID: fixture.panelId,
            onlyIfNeedsInput: true,
            clearNotificationsIfResumed: true
        )
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?["codex"] == .running)
        #expect(fixture.store.notifications.isEmpty)
    }
}
