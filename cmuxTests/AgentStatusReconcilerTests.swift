import CmuxSidebar
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent status reconciliation")
struct AgentStatusReconcilerTests {
    private let reconciler = AgentStatusReconciler()
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func lostStopCannotPinRunningForever() {
        let evidence = AgentStatusEvidence(
            lifecycle: .running,
            lifecycleObservedAt: now.addingTimeInterval(-121),
            shellActivity: .commandRunning
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .unknown, confidence: .uncertain))
    }

    @Test func recentOutputFromMatchingForegroundAgentInfersRunning() {
        let evidence = AgentStatusEvidence(
            lifecycle: .running,
            lifecycleObservedAt: now.addingTimeInterval(-121),
            outputObservedAt: now.addingTimeInterval(-2),
            foregroundAgentStatusKey: "codex",
            foregroundObservedAt: now.addingTimeInterval(-2),
            shellActivity: .commandRunning
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .running, confidence: .inferred))
    }

    @Test func unrelatedForegroundOutputCannotKeepAgentRunning() {
        let evidence = AgentStatusEvidence(
            lifecycle: .running,
            lifecycleObservedAt: now.addingTimeInterval(-121),
            outputObservedAt: now.addingTimeInterval(-2),
            foregroundAgentStatusKey: "claude_code",
            foregroundObservedAt: now.addingTimeInterval(-2),
            shellActivity: .commandRunning
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .unknown, confidence: .uncertain))
    }

    @Test func promptIdleOverridesRecentTerminalActivity() {
        let evidence = AgentStatusEvidence(
            lifecycle: .running,
            lifecycleObservedAt: now,
            outputObservedAt: now,
            foregroundAgentStatusKey: "codex",
            foregroundObservedAt: now,
            shellActivity: .promptIdle
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .idle, confidence: .confident))
    }

    @Test func freshNeedsInputOverridesStalePromptIdleShellState() {
        let evidence = AgentStatusEvidence(
            lifecycle: .needsInput,
            lifecycleObservedAt: now,
            shellActivity: .promptIdle
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .needsInput, confidence: .confident))
    }

    @Test func deadRuntimeRemovesDerivedStatus() {
        let evidence = AgentStatusEvidence(
            lifecycle: .running,
            lifecycleObservedAt: now,
            shellActivity: .commandRunning
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: false,
            now: now
        )

        #expect(resolution == nil)
    }

    @Test @MainActor func workspacePeriodicReconciliationReplacesStaleRunningPill() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        workspace.recordAgentPID(
            key: "codex.session",
            pid: getpid(),
            panelId: panelId,
            refreshPorts: false
        )
        workspace.statusEntries["codex"] = SidebarStatusEntry(
            key: "codex",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF",
            timestamp: now.addingTimeInterval(-121)
        )
        workspace.sidebarAgentRuntimeObservation.agentStatusLedger.recordLifecycle(
            .running,
            panelId: panelId,
            statusKey: "codex",
            observedAt: now.addingTimeInterval(-121)
        )

        workspace.reconcileAgentStatuses(panelId: panelId, now: now)

        #expect(workspace.statusEntries["codex"]?.icon == "questionmark.circle")
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["codex"] == .unknown)
    }

    @Test @MainActor func workspaceAggregateTimestampCannotRefreshPanelLifecycleEvidence() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        workspace.recordAgentPID(
            key: "codex.session",
            pid: getpid(),
            panelId: panelId,
            refreshPorts: false
        )
        workspace.agentLifecycleStatesByPanelId[panelId, default: [:]]["codex"] = .running
        workspace.statusEntries["codex"] = SidebarStatusEntry(
            key: "codex",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF",
            timestamp: now
        )

        workspace.reconcileAgentStatuses(panelId: panelId, now: now)

        #expect(workspace.statusEntries["codex"]?.icon == "questionmark.circle")
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["codex"] == .unknown)
    }

    @Test func freshNeedsInputRemainsConfidentDuringPromptRendering() {
        let signalTime = now.addingTimeInterval(-2)
        let evidence = AgentStatusEvidence(
            lifecycle: .needsInput,
            lifecycleObservedAt: signalTime,
            outputObservedAt: signalTime.addingTimeInterval(1),
            foregroundAgentStatusKey: "codex",
            foregroundObservedAt: now,
            shellActivity: .commandRunning
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .needsInput, confidence: .confident))
    }

    @Test func staleNeedsInputDegradesHonestly() {
        let evidence = AgentStatusEvidence(
            lifecycle: .needsInput,
            lifecycleObservedAt: now.addingTimeInterval(-301),
            foregroundAgentStatusKey: "codex",
            foregroundObservedAt: now,
            shellActivity: .commandRunning
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .unknown, confidence: .uncertain))
    }

    @Test func restoredIdleWithoutPanelLocalTimestampDegradesHonestly() {
        let evidence = AgentStatusEvidence(
            lifecycle: .idle,
            shellActivity: .commandRunning
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .unknown, confidence: .uncertain))
    }

    @Test @MainActor func titleActivityIsThrottledPerPanelStatus() {
        let ledger = AgentStatusRuntimeLedger()
        let panelId = UUID()
        ledger.recordTitle(panelId: panelId, statusKeys: ["codex"], observedAt: now)
        ledger.recordTitle(
            panelId: panelId,
            statusKeys: ["codex"],
            observedAt: now.addingTimeInterval(1)
        )

        #expect(ledger.evidenceForPanel(panelId)["codex"]?.titleObservedAt == now)

        ledger.recordTitle(
            panelId: panelId,
            statusKeys: ["codex"],
            observedAt: now.addingTimeInterval(5)
        )
        #expect(
            ledger.evidenceForPanel(panelId)["codex"]?.titleObservedAt == now.addingTimeInterval(5)
        )
    }

    @Test @MainActor func clearingNeedsInputPanelReprojectsSurvivingRunningPanel() throws {
        let workspace = Workspace()
        let needsInputPanelId = try #require(workspace.focusedPanelId)
        let runningPanel = try #require(
            workspace.newTerminalSplit(
                from: needsInputPanelId,
                orientation: .horizontal,
                focus: false
            )
        )
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }
        workspace.recordAgentPID(
            key: "codex.needs-input",
            pid: getpid(),
            panelId: needsInputPanelId,
            refreshPorts: false
        )
        workspace.setAgentLifecycle(
            key: "codex",
            panelId: needsInputPanelId,
            lifecycle: .needsInput
        )
        workspace.recordAgentPID(
            key: "codex.running",
            pid: getpid(),
            panelId: runningPanel.id,
            refreshPorts: false
        )
        workspace.setAgentLifecycle(
            key: "codex",
            panelId: runningPanel.id,
            lifecycle: .running
        )

        #expect(workspace.statusEntries["codex"]?.icon == "bell.fill")

        workspace.clearAgentPID(
            key: "codex.needs-input",
            panelId: needsInputPanelId,
            clearStatus: true,
            refreshPorts: false
        )

        #expect(workspace.statusEntries["codex"]?.icon == "bolt.fill")
    }

    @Test func codexPermissionTelemetryCarriesNeedsInputWithoutBecomingActionable() throws {
        let event = WorkstreamEvent(
            sessionId: "codex-session",
            hookEventName: .preToolUse,
            source: "codex",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            receivedAt: now,
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"needsInput"}"#
        )

        let signal = try #require(AgentStatusHookEventSignal(event: event))

        #expect(signal.statusKey == "codex")
        #expect(signal.lifecycle == .needsInput)
        #expect(signal.observedAt == now)
        #expect(FeedCoordinator.isBlockingDecisionEvent(event.hookEventName) == false)
    }

    @Test func ordinaryFeedTelemetryDoesNotBypassLifecycleRouting() {
        let event = WorkstreamEvent(
            sessionId: "codex-session",
            hookEventName: .stop,
            source: "codex",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            receivedAt: now
        )

        #expect(AgentStatusHookEventSignal(event: event) == nil)
    }

    @Test func liveEventRouteOutranksPersistedSessionFallback() throws {
        let workspaceId = UUID()
        let surfaceId = UUID()
        let event = WorkstreamEvent(
            sessionId: "codex-unmapped-session",
            hookEventName: .postToolUse,
            source: "codex",
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId.uuidString,
            receivedAt: now
        )

        let target = try #require(FeedCoordinator.resolveAttentionTarget(event: event))

        #expect(target.workspaceId == workspaceId)
        #expect(target.surfaceId == surfaceId)
    }

    @Test @MainActor func missingStatusSurfaceDoesNotGuessFocusedPanel() throws {
        let workspace = Workspace()
        _ = try #require(workspace.focusedPanelId)

        #expect(FeedCoordinator.resolvePanelId(surfaceId: nil, tab: workspace) == nil)
    }
}
