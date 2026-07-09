import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentHibernationPlannerSwiftTests {
    @MainActor
    @Test
    func agentPIDMutationInvalidatesPendingHibernationTeardown() throws {
        let controller = AgentHibernationController.shared
        let wasEnabled = AgentHibernationTrackingGate.isEnabled()
        defer { AgentHibernationTrackingGate.setEnabled(wasEnabled) }
        defer { resetSharedHibernationState(controller) }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panelKey = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelId)
        let baselineEpoch = controller.teardownValidationEpochByPanel[panelKey] ?? 0

        AgentHibernationTrackingGate.setEnabled(true)
        workspace.recordAgentPID(
            key: "codex.live-session",
            pid: 12_345,
            panelId: panelId,
            refreshPorts: false
        )
        let recordEpoch = try #require(controller.teardownValidationEpochByPanel[panelKey])
        #expect(recordEpoch == baselineEpoch + 1)

        AgentHibernationTrackingGate.setEnabled(true)
        workspace.clearAgentPID(
            key: "codex.live-session",
            panelId: panelId,
            clearStatus: true,
            refreshPorts: false
        )
        #expect(controller.teardownValidationEpochByPanel[panelKey] == recordEpoch + 1)
    }

    @MainActor
    @Test
    func agentPIDRefreshDoesNotInvalidatePendingHibernationTeardown() throws {
        let controller = AgentHibernationController.shared
        let wasEnabled = AgentHibernationTrackingGate.isEnabled()
        defer { AgentHibernationTrackingGate.setEnabled(wasEnabled) }
        defer { resetSharedHibernationState(controller) }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panelKey = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelId)

        AgentHibernationTrackingGate.setEnabled(true)
        workspace.recordAgentPID(
            key: "codex.live-session",
            pid: getpid(),
            panelId: panelId,
            refreshPorts: false
        )
        let recordEpoch = try #require(controller.teardownValidationEpochByPanel[panelKey])
        controller.activityByPanel[panelKey] = 123

        workspace.recordAgentPID(
            key: "codex.live-session",
            pid: getpid(),
            panelId: panelId,
            refreshPorts: false
        )

        #expect(controller.teardownValidationEpochByPanel[panelKey] == recordEpoch)
        #expect(controller.activityByPanel[panelKey] == 123)
    }

    @MainActor
    @Test
    func teardownRecordRejectsPanelMovedToAnotherWorkspace() throws {
        let source = Workspace()
        let panelId = try #require(source.focusedPanelId)
        let panel = try #require(source.panels[panelId] as? TerminalPanel)
        let record = AgentHibernationRecord(
            key: AgentHibernationPanelKey(workspaceId: source.id, panelId: panelId),
            workspace: source,
            terminalPanel: panel,
            agent: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "codex-moved-before-teardown",
                workingDirectory: "/tmp/cmux-agent-hibernation",
                launchCommand: nil
            ),
            lifecycle: .idle,
            hasUnconfirmedTerminalInput: false,
            lastActivityAt: 0,
            isProtected: false,
            hasLiveProcess: false,
            processIDs: []
        )
        #expect(record.isStillOwnedByOriginalWorkspace)

        let detached = try #require(source.detachSurface(panelId: panelId))
        let destination = Workspace()
        let destinationPaneId = try #require(destination.bonsplitController.focusedPaneId)
        #expect(destination.attachDetachedSurface(detached, inPane: destinationPaneId, focus: false) == panelId)

        #expect(record.isStillOwnedByOriginalWorkspace == false)
    }

    @Test
    func liveScopedProcessCreatesPressureButIsNotSelected() {
        let workspaceId = UUID()
        let now: TimeInterval = 1_000
        let runningAgent = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let exitedAgent = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let settings = AgentHibernationSettings.Values(
            enabled: true,
            idleSeconds: 60,
            maxLiveTerminals: 1,
            confirmationSeconds: 5
        )

        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [
                .init(
                    key: runningAgent,
                    hasRestorableAgent: true,
                    isLive: true,
                    hasLiveProcess: true,
                    isProtected: false,
                    lifecycle: .idle,
                    hasUnconfirmedTerminalInput: false,
                    lastActivityAt: now - 300
                ),
                .init(
                    key: exitedAgent,
                    hasRestorableAgent: true,
                    isLive: true,
                    isProtected: false,
                    lifecycle: .idle,
                    hasUnconfirmedTerminalInput: false,
                    lastActivityAt: now - 200
                ),
            ],
            settings: settings,
            now: now
        )

        #expect(selected == Set([exitedAgent]))
    }

    @MainActor
    @Test
    func unableToProtectMarkerExpiresSoTransientSnapshotFailuresRetry() {
        let marker = AgentHibernationController.UnableToProtectMarker(
            fingerprint: "tail:abc",
            lastActivityAt: 100,
            retryAfter: 220
        )

        #expect(AgentHibernationController.unableToProtectMarkerStillApplies(
            marker,
            fingerprint: "tail:abc",
            lastActivityAt: 100,
            now: 219
        ))
        #expect(AgentHibernationController.unableToProtectMarkerStillApplies(
            marker,
            fingerprint: "tail:abc",
            lastActivityAt: 100,
            now: 220
        ) == false)
        #expect(AgentHibernationController.unableToProtectMarkerStillApplies(
            marker,
            fingerprint: "tail:changed",
            lastActivityAt: 100,
            now: 219
        ) == false)
        #expect(AgentHibernationController.unableToProtectMarkerStillApplies(
            marker,
            fingerprint: "tail:abc",
            lastActivityAt: 101,
            now: 219
        ) == false)
    }

    @MainActor
    @Test
    func postSnapshotValidationDoesNotReuseTaskStartedBeforeSnapshotPoint() {
        let controller = AgentHibernationController.shared
        defer { resetSharedHibernationState(controller) }

        let staleRequestID = UUID()
        let staleTask = Task<RestorableAgentSessionIndex, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return .empty
        }
        controller.postSnapshotValidationIndexSequence = 1
        controller.postSnapshotValidationIndexTask = AgentHibernationController.PostSnapshotValidationIndexTask(
            requestID: staleRequestID,
            startSequence: 1,
            task: staleTask
        )
        controller.postSnapshotValidationIndexSequence = 2

        _ = controller.sharedPostSnapshotValidationIndexTask(minimumStartSequence: 2)

        #expect(controller.postSnapshotValidationIndexTask?.requestID != staleRequestID)
        #expect(controller.postSnapshotValidationIndexTask?.startSequence == 2)
    }

    @MainActor
    private func resetSharedHibernationState(_ controller: AgentHibernationController) {
        controller.activityByPanel.removeAll(keepingCapacity: false)
        controller.terminalInputByPanel.removeAll(keepingCapacity: false)
        controller.lifecycleChangeByPanel.removeAll(keepingCapacity: false)
        controller.teardownValidationEpochByPanel.removeAll(keepingCapacity: false)
        controller.unableToProtectByPanel.removeAll(keepingCapacity: false)
        controller.cancelPostTeardownRestoreTasks()
        controller.postSnapshotValidationIndexTask?.task.cancel()
        controller.postSnapshotValidationIndexSequence = 0
        controller.postSnapshotValidationIndexTask = nil
    }
}
