import Darwin
import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent status reconciliation recovery")
struct AgentStatusReconciliationRecoveryTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func promptIdleWithoutRecencyDegradesHonestly() {
        let resolution = AgentStatusReconciler().resolve(
            evidence: AgentStatusEvidence(shellActivity: .promptIdle),
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .unknown, confidence: .uncertain))
    }

    @Test @MainActor func replacementRuntimeAcceptsRestartedLifecycleRevision() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let firstPID = getpid()
        let replacementPID = getppid()
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }

        workspace.recordAgentPID(
            key: "codex.session",
            pid: firstPID,
            panelId: panelID,
            refreshPorts: false
        )
        let oldGeneration = try #require(AgentStatusHookEventSignal(event: WorkstreamEvent(
            sessionId: "codex-session",
            hookEventName: .preToolUse,
            source: "codex",
            ppid: Int(firstPID),
            receivedAt: now,
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"running","_cmux_agent_status_revision":5}"#
        )))
        workspace.noteAgentStatusHookSignal(oldGeneration, panelId: panelID)

        workspace.recordAgentPID(
            key: "codex.session",
            pid: replacementPID,
            panelId: panelID,
            refreshPorts: false
        )
        let newGeneration = try #require(AgentStatusHookEventSignal(event: WorkstreamEvent(
            sessionId: "codex-session",
            hookEventName: .permissionRequest,
            source: "codex",
            ppid: Int(replacementPID),
            receivedAt: now.addingTimeInterval(1),
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"needsInput","_cmux_agent_status_revision":1}"#
        )))
        workspace.noteAgentStatusHookSignal(newGeneration, panelId: panelID)

        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?["codex"] == .needsInput)
    }

    @Test @MainActor func remotePromptIdleObservedAfterApprovalClearsNeedsInput() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let remotePID: pid_t = 987_654
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        workspace.trackRemoteTerminalSurface(panelID)
        workspace.recordAgentPID(
            key: "codex.remote-session",
            pid: remotePID,
            panelId: panelID,
            refreshPorts: false
        )
        workspace.updatePanelShellActivityState(panelId: panelID, state: .commandRunning)
        let permission = try #require(AgentStatusHookEventSignal(event: WorkstreamEvent(
            sessionId: "codex-remote-session",
            hookEventName: .permissionRequest,
            source: "codex",
            ppid: Int(remotePID),
            receivedAt: now,
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"needsInput","_cmux_agent_status_revision":1,"_cmux_agent_pid_namespace":"remote"}"#
        )))
        workspace.noteAgentStatusHookSignal(permission, panelId: panelID)
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?["codex"] == .needsInput)

        workspace.updatePanelShellActivityState(panelId: panelID, state: .promptIdle)

        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?["codex"] == .idle)
    }

    @Test @MainActor func remoteSamePIDSessionRestartAcceptsNewGenerationRevision() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let remotePID: pid_t = 987_654
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        workspace.trackRemoteTerminalSurface(panelID)
        workspace.recordAgentPID(
            key: "codex.remote-session",
            pid: remotePID,
            panelId: panelID,
            refreshPorts: false
        )
        let previousGeneration = try #require(AgentStatusHookEventSignal(event: WorkstreamEvent(
            sessionId: "codex-remote-session",
            hookEventName: .preToolUse,
            source: "codex",
            ppid: Int(remotePID),
            receivedAt: now,
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"running","_cmux_agent_status_revision":8,"_cmux_agent_pid_namespace":"remote","_cmux_agent_pid_start_seconds":10,"_cmux_agent_pid_start_microseconds":20}"#
        )))
        workspace.noteAgentStatusHookSignal(previousGeneration, panelId: panelID)

        let replacementGeneration = try #require(AgentStatusHookEventSignal(event: WorkstreamEvent(
            sessionId: "codex-remote-session",
            hookEventName: .permissionRequest,
            source: "codex",
            ppid: Int(remotePID),
            receivedAt: now.addingTimeInterval(1),
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"needsInput","_cmux_agent_status_revision":1,"_cmux_agent_pid_namespace":"remote","_cmux_agent_pid_start_seconds":11,"_cmux_agent_pid_start_microseconds":30}"#
        )))
        workspace.noteAgentStatusHookSignal(replacementGeneration, panelId: panelID)

        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?["codex"] == .needsInput)

        let delayedPreviousGeneration = try #require(AgentStatusHookEventSignal(event: WorkstreamEvent(
            sessionId: "codex-remote-session",
            hookEventName: .preToolUse,
            source: "codex",
            ppid: Int(remotePID),
            receivedAt: now.addingTimeInterval(2),
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"running","_cmux_agent_status_revision":9,"_cmux_agent_pid_namespace":"remote","_cmux_agent_pid_start_seconds":10,"_cmux_agent_pid_start_microseconds":20}"#
        )))
        workspace.noteAgentStatusHookSignal(delayedPreviousGeneration, panelId: panelID)

        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?["codex"] == .needsInput)

        let didResume = workspace.resumeAgentLifecycleIfNeedsInput(
            key: "codex",
            panelId: panelID,
            runtimePIDKey: replacementGeneration.runtimePIDKey,
            runtimePID: replacementGeneration.runtimePID,
            runtimeProcessIdentity: replacementGeneration.runtimeProcessIdentity,
            revision: 2
        )
        #expect(didResume)
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?["codex"] == .running)
    }

    @Test @MainActor func remoteFeedPIDDoesNotArmDarwinProcessWatcher() async {
        let store = WorkstreamStore(ringCapacity: 10)
        FeedCoordinator.shared.install(store: store)
        var watchedPIDs: [Int] = []
        FeedCoordinatorTestHooks.pidWatcherArmObserver = { watchedPIDs.append($0) }
        defer { FeedCoordinatorTestHooks.pidWatcherArmObserver = nil }
        let event = WorkstreamEvent(
            sessionId: "codex-remote-session",
            hookEventName: .permissionRequest,
            source: "codex",
            requestId: nil,
            ppid: 987_654,
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"needsInput","_cmux_agent_pid_namespace":"remote"}"#
        )

        _ = FeedCoordinator.shared.ingestBlocking(event: event, waitTimeout: 0)
        while store.items.isEmpty { await Task.yield() }

        #expect(watchedPIDs.isEmpty)
        #expect(store.pending.count == 1)
    }

    @Test func restoredRemoteFeedItemDoesNotArmDarwinProcessWatcher() {
        let remoteItem = WorkstreamItem(
            workstreamId: "codex-remote-session",
            source: .codex,
            kind: .permissionRequest,
            payload: .permissionRequest(
                requestId: "remote-permission",
                toolName: "shell",
                toolInputJSON: "{}",
                pattern: nil
            ),
            ppid: 987_654,
            processNamespace: .remote
        )

        #expect(!FeedCoordinator.shouldArmPIDWatcher(for: remoteItem))
    }

    @Test @MainActor func acceptedLifecycleStartsANewShellObservationEpoch() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let fastPath = TerminalController.shared.socketFastPathState
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        workspace.recordAgentPID(
            key: "codex.session",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        #expect(fastPath.shouldPublishShellActivity(
            workspaceId: workspace.id,
            panelId: panelID,
            state: PanelShellActivityState.promptIdle.rawValue
        ))
        #expect(!fastPath.shouldPublishShellActivity(
            workspaceId: workspace.id,
            panelId: panelID,
            state: PanelShellActivityState.promptIdle.rawValue
        ))
        let running = try #require(AgentStatusHookEventSignal(event: WorkstreamEvent(
            sessionId: "codex-session",
            hookEventName: .preToolUse,
            source: "codex",
            ppid: Int(getpid()),
            receivedAt: now,
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"running"}"#
        )))

        workspace.noteAgentStatusHookSignal(running, panelId: panelID)

        #expect(fastPath.shouldPublishShellActivity(
            workspaceId: workspace.id,
            panelId: panelID,
            state: PanelShellActivityState.promptIdle.rawValue
        ))
    }

    @Test func turnOnlyPermissionDoesNotGuessBetweenParallelTools() {
        let runtime = CodexPermissionRuntimeGeneration(
            pid: 4_242,
            pidStartSeconds: 10,
            pidStartMicroseconds: 20
        )
        let firstTool = CodexPermissionSignalIdentity(turnID: "turn-1", requestID: "call-1")
        let secondTool = CodexPermissionSignalIdentity(turnID: "turn-1", requestID: "call-2")
        let firstStarted = CodexPermissionTransitionMachine.reduce(
            current: nil,
            event: .toolStarted,
            identity: firstTool,
            runtime: runtime
        )
        let secondStarted = CodexPermissionTransitionMachine.reduce(
            current: firstStarted.state,
            event: .toolStarted,
            identity: secondTool,
            runtime: runtime
        )
        let permission = CodexPermissionTransitionMachine.reduce(
            current: secondStarted.state,
            event: .permissionRequested,
            identity: CodexPermissionSignalIdentity(turnID: "turn-1", requestID: nil),
            runtime: runtime
        )

        #expect(permission.state.identity.requestID == nil)

        let unrelatedCompletion = CodexPermissionTransitionMachine.reduce(
            current: permission.state,
            event: .toolCompleted,
            identity: secondTool,
            runtime: runtime
        )
        #expect(unrelatedCompletion.effect == .none)
        #expect(unrelatedCompletion.state.phase == .needsInput)
    }

    @Test @MainActor func stalledDetectorDoesNotBlockLifecycleExpiryOrSpawnAnotherDetector() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        workspace.recordAgentPID(
            key: "codex.current",
            pid: getpid(),
            panelId: panelID,
            refreshPorts: false
        )
        workspace.updatePanelShellActivityState(panelId: panelID, state: .commandRunning)
        let running = try #require(AgentStatusHookEventSignal(event: WorkstreamEvent(
            sessionId: "codex-current",
            hookEventName: .preToolUse,
            source: "codex",
            ppid: Int(getpid()),
            receivedAt: now,
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"running"}"#
        )))
        workspace.noteAgentStatusHookSignal(running, panelId: panelID)
        let detector = StalledAgentStatusDetector()
        let coordinator = AgentStatusReconciliationCoordinator { _, _ in
            await detector.detect()
            return [:]
        }
        let cycleStart = ContinuousClock.now
        let stalledSweep = try #require(coordinator.reconcile(
            tabManagers: [manager],
            at: cycleStart,
            observedAt: now
        ))
        while await detector.callCount == 0 { await Task.yield() }

        let replacementSweep = coordinator.reconcile(
            tabManagers: [manager],
            at: cycleStart.advanced(by: .seconds(31)),
            observedAt: now.addingTimeInterval(91)
        )

        #expect(replacementSweep == nil)
        #expect(await detector.callCount == 1)
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?["codex"] == .unknown)
        await detector.resumeAll()
        await stalledSweep.value
        await replacementSweep?.value
    }
}

private actor StalledAgentStatusDetector {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0

    func detect() async {
        callCount += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
