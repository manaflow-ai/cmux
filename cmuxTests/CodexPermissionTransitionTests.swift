import CMUXAgentLaunch
import Foundation
import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Codex permission transitions")
struct CodexPermissionTransitionTests {
    private let permissionMachine = CodexPermissionTransitionMachine()
    private let runtime = CodexPermissionRuntimeGeneration(
        pid: 4_242,
        pidStartSeconds: 10,
        pidStartMicroseconds: 20
    )

    @Test func notificationIdentityPersistsUntilTheExactPermissionResolves() throws {
        let identity = CodexPermissionSignalIdentity(turnID: "turn-id", requestID: "call-id")
        let notificationID = UUID()
        let requested = permissionMachine.reduce(
            current: nil,
            event: .permissionRequested,
            identity: identity,
            runtime: runtime,
            notificationID: notificationID
        )
        let duplicate = permissionMachine.reduce(
            current: requested.state,
            event: .permissionRequested,
            identity: identity,
            runtime: runtime,
            notificationID: UUID()
        )
        let migrated = permissionMachine.reduce(
            current: CodexPermissionState(
                phase: .needsInput,
                identity: identity,
                runtime: runtime
            ),
            event: .permissionRequested,
            identity: identity,
            runtime: runtime,
            notificationID: notificationID
        )
        let resumed = permissionMachine.reduce(
            current: duplicate.state,
            event: .toolCompleted,
            identity: identity,
            runtime: runtime
        )
        let persisted = try JSONDecoder().decode(
            CodexPermissionState.self,
            from: JSONEncoder().encode(resumed.state)
        )

        #expect(requested.state.notificationID == notificationID)
        #expect(duplicate.state.notificationID == notificationID)
        #expect(migrated.state.notificationID == notificationID)
        #expect(resumed.effect == .resolveNeedsInput)
        #expect(persisted.notificationID == notificationID)
    }

    @Test func resumedTombstoneRejectsReorderedPermissionForSameRequest() {
        let identity = CodexPermissionSignalIdentity(turnID: "turn-1", requestID: "call-1")
        let resumed = permissionMachine.reduce(
            current: nil,
            event: .toolCompleted,
            identity: identity,
            runtime: runtime
        )
        let reorderedPermission = permissionMachine.reduce(
            current: resumed.state,
            event: .permissionRequested,
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
        let newerPermission = permissionMachine.reduce(
            current: resolved,
            event: .permissionRequested,
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
        let staleScopedResume = permissionMachine.reduce(
            current: pending,
            event: .toolCompleted,
            identity: CodexPermissionSignalIdentity(turnID: "turn-2", requestID: "call-old"),
            runtime: runtime
        )
        let unscopedResume = permissionMachine.reduce(
            current: pending,
            event: .toolCompleted,
            identity: CodexPermissionSignalIdentity(turnID: nil, requestID: nil),
            runtime: runtime
        )
        let exactResume = permissionMachine.reduce(
            current: pending,
            event: .toolCompleted,
            identity: pending.identity,
            runtime: runtime
        )

        #expect(staleScopedResume.accepted)
        #expect(staleScopedResume.effect == .none)
        #expect(staleScopedResume.state.phase == .needsInput)
        #expect(staleScopedResume.state.identity == pending.identity)
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
        let transition = permissionMachine.reduce(
            current: pending,
            event: .toolCompleted,
            identity: pending.identity,
            runtime: reusedPID
        )

        #expect(transition.accepted == false)
        #expect(transition.state == pending)
    }

    @Test func toolStartDoesNotResolvePendingPermission() {
        let identity = CodexPermissionSignalIdentity(turnID: "turn-3", requestID: "call-1")
        let pending = CodexPermissionState(
            phase: .needsInput,
            identity: identity,
            runtime: runtime
        )

        let started = permissionMachine.reduce(
            current: pending,
            event: .toolStarted,
            identity: identity,
            runtime: runtime
        )

        #expect(started.accepted)
        #expect(started.effect == .none)
        #expect(started.state.phase == .needsInput)
        #expect(started.state.identity == identity)
    }

    @Test func requestWithoutToolIDCorrelatesToOnlyActiveStartInSameTurn() {
        let first = CodexPermissionSignalIdentity(turnID: "turn-4", requestID: "call-1")
        let second = CodexPermissionSignalIdentity(turnID: "turn-4", requestID: "call-2")
        let firstStarted = permissionMachine.reduce(
            current: nil,
            event: .toolStarted,
            identity: first,
            runtime: runtime
        )
        let firstCompleted = permissionMachine.reduce(
            current: firstStarted.state,
            event: .toolCompleted,
            identity: first,
            runtime: runtime
        )
        let secondStarted = permissionMachine.reduce(
            current: firstCompleted.state,
            event: .toolStarted,
            identity: second,
            runtime: runtime
        )

        let requested = permissionMachine.reduce(
            current: secondStarted.state,
            event: .permissionRequested,
            identity: CodexPermissionSignalIdentity(turnID: "turn-4", requestID: nil),
            runtime: runtime
        )

        #expect(requested.accepted)
        #expect(requested.effect == .projectNeedsInput)
        #expect(requested.state.identity == second)
    }

    @Test func matchingToolCompletionResolvesCorrelatedPermission() {
        let tool = CodexPermissionSignalIdentity(turnID: "turn-5", requestID: "call-1")
        let started = permissionMachine.reduce(
            current: nil,
            event: .toolStarted,
            identity: tool,
            runtime: runtime
        )
        let requested = permissionMachine.reduce(
            current: started.state,
            event: .permissionRequested,
            identity: CodexPermissionSignalIdentity(turnID: "turn-5", requestID: nil),
            runtime: runtime
        )

        let completed = permissionMachine.reduce(
            current: requested.state,
            event: .toolCompleted,
            identity: tool,
            runtime: runtime
        )

        #expect(completed.accepted)
        #expect(completed.effect == .resolveNeedsInput)
        #expect(completed.state.phase == .resumed)
    }

    @Test func fullyUnscopedRequestCorrelatesToOnlyActiveStart() {
        let tool = CodexPermissionSignalIdentity(turnID: "turn-unscoped", requestID: "call-1")
        let started = permissionMachine.reduce(
            current: nil, event: .toolStarted, identity: tool, runtime: runtime
        )
        let requested = permissionMachine.reduce(
            current: started.state, event: .permissionRequested,
            identity: .init(turnID: nil, requestID: nil), runtime: runtime
        )
        #expect(requested.accepted)
        #expect(requested.state.identity == tool)
    }

    @Test func lateCompletionCannotClearNewerPermission() {
        let oldTool = CodexPermissionSignalIdentity(turnID: "turn-6", requestID: "call-old")
        let newTool = CodexPermissionSignalIdentity(turnID: "turn-6", requestID: "call-new")
        let oldStarted = permissionMachine.reduce(
            current: nil,
            event: .toolStarted,
            identity: oldTool,
            runtime: runtime
        )
        let oldRequested = permissionMachine.reduce(
            current: oldStarted.state,
            event: .permissionRequested,
            identity: oldTool,
            runtime: runtime
        )
        let newStarted = permissionMachine.reduce(
            current: oldRequested.state,
            event: .toolStarted,
            identity: newTool,
            runtime: runtime
        )
        let newRequested = permissionMachine.reduce(
            current: newStarted.state,
            event: .permissionRequested,
            identity: newTool,
            runtime: runtime
        )

        let oldCompletedLate = permissionMachine.reduce(
            current: newRequested.state,
            event: .toolCompleted,
            identity: oldTool,
            runtime: runtime
        )

        #expect(oldCompletedLate.accepted)
        #expect(oldCompletedLate.effect == .resolvePermission)
        #expect(oldCompletedLate.state.phase == .needsInput)
        #expect(oldCompletedLate.state.identity == newTool)
    }

    @Test func completionBeforePermissionTombstonesCorrelatedRequest() {
        let tool = CodexPermissionSignalIdentity(turnID: "turn-7", requestID: "call-1")
        let started = permissionMachine.reduce(
            current: nil,
            event: .toolStarted,
            identity: tool,
            runtime: runtime
        )
        let completed = permissionMachine.reduce(
            current: started.state,
            event: .toolCompleted,
            identity: tool,
            runtime: runtime
        )

        let permissionArrivedLate = permissionMachine.reduce(
            current: completed.state,
            event: .permissionRequested,
            identity: tool,
            runtime: runtime
        )

        #expect(permissionArrivedLate.accepted == false)
        #expect(permissionArrivedLate.effect == .none)
        #expect(permissionArrivedLate.state == completed.state)
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

@Suite("Codex permission delivery ordering")
struct CodexPermissionDeliveryOrderingTests {
    @Test @MainActor func lateNeedsInputSignalCannotOverrideNewerResumeRevision() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let pid = getpid()
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        workspace.recordAgentPID(
            key: "codex.session",
            pid: pid,
            panelId: panelID,
            refreshPorts: false
        )
        let identity = try #require(workspace.agentPIDProcessIdentitiesByKey["codex.session"])
        let resumed = try #require(AgentStatusHookEventSignal(event: WorkstreamEvent(
            sessionId: "codex-session",
            hookEventName: .preToolUse,
            source: "codex",
            ppid: Int(pid),
            receivedAt: Date.now,
            extraFieldsJSON: """
            {"_cmux_agent_status_signal":"running","_cmux_agent_status_revision":2,"_cmux_agent_pid_start_seconds":\(identity.startSeconds),"_cmux_agent_pid_start_microseconds":\(identity.startMicroseconds)}
            """
        )))
        let latePermission = try #require(AgentStatusHookEventSignal(event: WorkstreamEvent(
            sessionId: "codex-session",
            hookEventName: .permissionRequest,
            source: "codex",
            ppid: Int(pid),
            receivedAt: Date.now,
            extraFieldsJSON: """
            {"_cmux_agent_status_signal":"needsInput","_cmux_agent_status_revision":1,"_cmux_agent_pid_start_seconds":\(identity.startSeconds),"_cmux_agent_pid_start_microseconds":\(identity.startMicroseconds)}
            """
        )))

        workspace.noteAgentStatusHookSignal(resumed, panelId: panelID)
        workspace.noteAgentStatusHookSignal(latePermission, panelId: panelID)

        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?["codex"] == .running)
    }
}

extension AgentNotificationRegressionTests {
    @Test("PID-less Feed cleanup preserves an overlapping ordered approval")
    @MainActor
    func pidlessFeedCleanupPreservesOrderedNeedsInput() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let pid = getpid()
        fixture.source.recordAgentPID(
            key: "codex.session",
            pid: pid,
            panelId: fixture.panelId,
            refreshPorts: false
        )
        defer { fixture.source.clearAllAgentPIDs(refreshPorts: false) }
        let identity = try #require(fixture.source.agentPIDProcessIdentitiesByKey["codex.session"])
        let pidlessEvent = WorkstreamEvent(
            sessionId: "codex-internal",
            hookEventName: .permissionRequest,
            source: "codex",
            requestId: "pidless-approval"
        )
        let pidlessTarget = try #require(FeedCoordinator.shared.surfaceBlockingDecisionAttention(
            event: pidlessEvent,
            resolved: (fixture.source.id, fixture.panelId)
        ))
        let orderedEvent = WorkstreamEvent(
            sessionId: "codex-session",
            hookEventName: .permissionRequest,
            source: "codex",
            requestId: "ordered-approval",
            ppid: Int(pid),
            receivedAt: Date.now,
            extraFieldsJSON: """
            {"_cmux_agent_status_signal":"needsInput","_cmux_agent_status_revision":1,"_cmux_agent_pid_start_seconds":\(identity.startSeconds),"_cmux_agent_pid_start_microseconds":\(identity.startMicroseconds)}
            """
        )
        let orderedTarget = try #require(FeedCoordinator.shared.surfaceBlockingDecisionAttention(
            event: orderedEvent,
            resolved: (fixture.source.id, fixture.panelId)
        ))
        defer {
            FeedCoordinator.shared.concludeBlockingDecisionAttention(orderedTarget)
            FeedCoordinator.shared.concludeBlockingDecisionAttention(pidlessTarget)
        }

        #expect(pidlessTarget.clearsLifecycleOnConclusion)
        #expect(!orderedTarget.clearsLifecycleOnConclusion)
        FeedCoordinator.shared.concludeBlockingDecisionAttention(pidlessTarget)

        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?["codex"] == .needsInput)
        #expect(fixture.source.statusEntries["codex"]?.icon == "bell.fill")
    }

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
        let codexNotificationID = UUID()
        let unrelatedNotificationID = UUID()
        let bus = TerminalMutationBus.shared
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Codex",
            subtitle: "Needs approval",
            body: "Approve this tool",
            notificationID: codexNotificationID,
            coalesces: false
        )
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Build",
            subtitle: "Completed",
            body: "Unrelated panel notification",
            notificationID: unrelatedNotificationID,
            coalesces: false
        )

        TerminalController.shared.controlSidebarScheduleAgentLifecycle(
            target: .workspace(fixture.source.id),
            key: "codex",
            lifecycleRawValue: AgentHibernationLifecycleState.running.rawValue,
            panelID: fixture.panelId,
            onlyIfNeedsInput: true,
            notificationID: codexNotificationID,
            clearNotificationsIfResumed: true
        )
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?["codex"] == .running)
        #expect(fixture.store.notifications.map(\.id) == [unrelatedNotificationID])
    }
}
