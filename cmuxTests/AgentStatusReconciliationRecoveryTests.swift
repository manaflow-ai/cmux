import Darwin
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

    @Test @MainActor func staleSweepCanBeReplacedAfterItsDeadline() async throws {
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
        let coordinator = AgentStatusReconciliationCoordinator { _, _ in
            while !Task.isCancelled { await Task.yield() }
            return [:]
        }
        let cycleStart = ContinuousClock.now
        let stalledSweep = try #require(coordinator.reconcile(
            tabManagers: [manager],
            at: cycleStart,
            observedAt: now
        ))

        let replacementSweep = coordinator.reconcile(
            tabManagers: [manager],
            at: cycleStart.advanced(by: .seconds(31)),
            observedAt: now.addingTimeInterval(31)
        )

        #expect(replacementSweep != nil)
        stalledSweep.cancel()
        replacementSweep?.cancel()
        await stalledSweep.value
        await replacementSweep?.value
    }
}
