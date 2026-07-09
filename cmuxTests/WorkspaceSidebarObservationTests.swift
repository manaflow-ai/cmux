import Combine
import Foundation
import Observation
import Testing

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceSidebarObservationTests {
    @Test func sidebarObservationPublisherEmitsForLateStatusSubscriber() {
        let workspace = Workspace()
        workspace.statusEntries["test_probe"] = SidebarStatusEntry(
            key: "test_probe",
            value: "VISIBLE?",
            icon: "star.fill",
            color: "#FF0000",
            priority: 200
        )

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        #expect(
            publishCount > 0,
            "A sidebar row that subscribes after status metadata already exists must still refresh from the current workspace state."
        )
    }

    @Test func agentRuntimeObservationChangesWhenAgentPIDMakesExistingStatusVisible() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.statusEntries["codex"] = SidebarStatusEntry(
            key: "codex",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF"
        )
        #expect(
            !workspace.sidebarStatusEntriesInDisplayOrder().contains { $0.key == "codex" },
            "Structured agent statuses stay hidden until a live agent runtime owns the status key."
        )

        let generationBeforeRecord = workspace.sidebarAgentRuntimeObservation.changeGeneration
        var workspaceWillChangeCount = 0
        let objectWillChangeCancellable = workspace.objectWillChange.sink {
            workspaceWillChangeCount += 1
        }
        defer { objectWillChangeCancellable.cancel() }

        workspace.recordAgentPID(
            key: "codex.session-b",
            pid: 12_345,
            panelId: panelId,
            refreshPorts: false
        )

        #expect(
            workspace.sidebarStatusEntriesInDisplayOrder().contains { $0.key == "codex" },
            "Recording the agent PID makes the existing Running status visible."
        )
        #expect(
            workspace.sidebarAgentRuntimeObservation.changeGeneration > generationBeforeRecord,
            "Agent PID ownership changes must notify the sidebar row runtime observation stream."
        )
        #expect(
            workspaceWillChangeCount == 0,
            "Agent PID ownership is sidebar presentation state and must not broadly invalidate Workspace observers."
        )
    }

    @Test func terminalAgentContextDoesNotObserveAgentRuntimeMaps() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId])
        let changeFlag = ObservationChangeFlag()

        withObservationTracking {
            _ = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        } onChange: {
            changeFlag.mark()
        }

        workspace.recordAgentPID(
            key: "codex.session-c",
            pid: 12_346,
            panelId: panelId,
            refreshPorts: false
        )

        #expect(
            changeFlag.fired == false,
            "Terminal content must not subscribe to sidebar-only agent runtime map churn."
        )
    }

    @Test func sidebarImmediateObservationPublisherEmitsForLateTitleSubscriber() {
        let workspace = Workspace()
        workspace.title = "Restored Workspace"

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        #expect(
            publishCount > 0,
            "A sidebar row that subscribes after immediate workspace fields already exist must still refresh from the current workspace state."
        )
    }

    @Test func sidebarImmediateObservationPublisherDeliversFirstChangeSynchronously() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.title = "User Edit"

        #expect(
            publishCount == 1,
            "The first immediate-field change after subscribing must reach the sidebar in the same run-loop turn; coalescing may only defer the tail of a burst."
        )
    }

    @Test func sidebarImmediateObservationPublisherCoalescesTitleBursts() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        for turn in 0..<20 {
            workspace.title = "Agent Turn \(turn)"
        }

        #expect(
            publishCount == 1,
            "A synchronous burst of distinct titles must deliver only its leading edge immediately."
        )

        // Generous pump so the 50ms trailing emission fires deterministically.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        #expect(
            publishCount == 2,
            "A coalesced burst must settle with exactly one trailing emission carrying the latest state."
        )
    }

    @Test func coalesceLatestKeepsLeadingEdgeSynchronousAndEmitsLatestTrailing() {
        let subject = PassthroughSubject<Int, Never>()
        var received: [Int] = []
        let cancellable = subject
            .coalesceLatest(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        // First value models the @Published current-state replay: forwarded
        // synchronously without opening a coalesce window.
        subject.send(1)
        #expect(received == [1])

        // First change is the synchronous leading edge and opens the window.
        subject.send(2)
        #expect(received == [1, 2])

        // Burst inside the window coalesces to the latest value.
        subject.send(3)
        subject.send(4)
        subject.send(5)
        #expect(received == [1, 2])

        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(received == [1, 2, 5])

        // After the window closes and the trailing window expires, the next
        // value is synchronous again.
        subject.send(6)
        #expect(received == [1, 2, 5, 6])
    }

    @Test func coalesceLatestDropsStalePendingValueWhenLeadingSupersedesOverdueTrailing() {
        let scheduler = VirtualCoalesceScheduler()
        let subject = PassthroughSubject<Int, Never>()
        var received: [Int] = []
        let cancellable = subject
            .coalesceLatest(for: .milliseconds(50), scheduler: scheduler)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        subject.send(1) // replay: forwarded, no window
        subject.send(2) // leading edge: opens window
        subject.send(3) // pending trailing value for the open window
        #expect(received == [1, 2])
        #expect(scheduler.scheduledActionCount == 1)

        // The deadline passes WITHOUT the scheduled callback running,
        // modeling a stalled main run loop with an overdue timer.
        scheduler.advance(by: 0.12)
        subject.send(4) // deadline passed: new leading edge must supersede 3

        #expect(
            received == [1, 2, 4],
            "A newer leading value after an overdue deadline must drop the stale pending value."
        )

        scheduler.runScheduledActions()
        #expect(
            received == [1, 2, 4],
            "The overdue trailing callback must not emit the superseded stale value out of order."
        )
    }

    @Test func sidebarObservationPublisherIgnoresRemoteHeartbeatOnlyChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.remoteHeartbeatCount = 1
        workspace.remoteLastHeartbeatAt = Date()

        #expect(
            publishCount == 0,
            "Expected non-visible remote heartbeat updates to avoid invalidating sidebar rows"
        )
    }

    @Test func agentLifecycleChangeBumpsRuntimeObservationGeneration() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let before = workspace.sidebarAgentRuntimeObservation.changeGeneration

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        #expect(
            workspace.sidebarAgentRuntimeObservation.changeGeneration > before,
            "Agent lifecycle changes must notify sidebar rows so the loading spinner updates."
        )
    }

    @Test func redundantAgentLifecycleWriteDoesNotNotifySidebarRows() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        let before = workspace.sidebarAgentRuntimeObservation.changeGeneration

        // Re-asserting the same lifecycle value must not churn row refreshes.
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        #expect(workspace.sidebarAgentRuntimeObservation.changeGeneration == before)
    }

    @Test func clearAgentLifecycleWithNilPanelClearsKeySetOnSpecificPanel() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)
        #expect(
            SidebarAgentActivitySummary.activeCodingAgentCount(
                statesByPanelId: workspace.agentLifecycleStatesByPanelId
            ) == 1
        )

        // The workspace-scoped `cmux workspace loading off` path clears with a
        // nil panel id; it must remove the key even though `on` targeted a
        // specific panel (the cross-surface off bug).
        #expect(workspace.clearAgentLifecycle(key: "manual", panelId: nil))
        #expect(
            SidebarAgentActivitySummary.activeCodingAgentCount(
                statesByPanelId: workspace.agentLifecycleStatesByPanelId
            ) == 0
        )
    }

    @Test func runningLifecycleQueryIsScopedToOneLoaderKey() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)

        #expect(workspace.hasRunningAgentLifecycle(key: "manual"))
        #expect(workspace.clearAgentLifecycle(key: "manual", panelId: nil))
        #expect(!workspace.hasRunningAgentLifecycle(key: "manual"))
        #expect(workspace.hasRunningAgentLifecycle(key: "codex"))
        #expect(
            SidebarAgentActivitySummary.activeCodingAgentCount(
                statesByPanelId: workspace.agentLifecycleStatesByPanelId
            ) == 1
        )
    }

    @Test func clearAgentLifecycleStatesPreservesManualLoadersOnLivePanel() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)

        // Agent lifecycle resets clear agent keys but must not drop the
        // workspace-scoped manual loader with them.
        workspace.clearAgentLifecycleStates(panelId: panelId)

        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["codex"] == nil)
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["manual"] == .running)
    }

    @Test func activeCodingAgentCountOnlyCountsRunningAgents() {
        let firstPanelId = UUID()
        let secondPanelId = UUID()

        let count = SidebarAgentActivitySummary.activeCodingAgentCount(
            statesByPanelId: [
                firstPanelId: [
                    "codex": .running,
                    "claude_code": .idle,
                    "gemini": .needsInput,
                ],
                secondPanelId: [
                    "opencode": .running,
                    "kiro": .unknown,
                ],
            ]
        )

        #expect(count == 2)
    }

    @Test func visibleActiveCodingAgentCountReturnsZeroWhenSettingIsDisabled() {
        let panelId = UUID()
        let statesByPanelId = [
            panelId: [
                "codex": AgentHibernationLifecycleState.running,
                "claude_code": AgentHibernationLifecycleState.running,
            ],
        ]

        #expect(
            SidebarAgentActivitySummary.visibleActiveCodingAgentCount(
                showsAgentActivity: false,
                statesByPanelId: statesByPanelId
            ) == 0
        )
        #expect(
            SidebarAgentActivitySummary.visibleActiveCodingAgentCount(
                showsAgentActivity: true,
                statesByPanelId: statesByPanelId
            ) == 2
        )
    }
}

// Mutable flag captured by Observation's Sendable onChange closure in this test.
private final class ObservationChangeFlag: @unchecked Sendable {
    private(set) var fired = false

    func mark() {
        fired = true
    }
}

// Deterministic Combine scheduler for coalesceLatest tests: `now` only moves
// via advance(by:), and scheduled actions run only when runScheduledActions()
// is called, so overdue-timer interleavings are exact instead of wall-clock.
private final class VirtualCoalesceScheduler: Scheduler {
    typealias SchedulerTimeType = RunLoop.SchedulerTimeType
    typealias SchedulerOptions = Never

    private(set) var now = SchedulerTimeType(Date(timeIntervalSinceReferenceDate: 0))
    var minimumTolerance: SchedulerTimeType.Stride { .seconds(0) }
    private var scheduledActions: [() -> Void] = []

    var scheduledActionCount: Int { scheduledActions.count }

    func advance(by seconds: TimeInterval) {
        now = SchedulerTimeType(now.date.addingTimeInterval(seconds))
    }

    func runScheduledActions() {
        let actions = scheduledActions
        scheduledActions = []
        actions.forEach { $0() }
    }

    func schedule(options: Never?, _ action: @escaping () -> Void) {
        action()
    }

    func schedule(
        after date: SchedulerTimeType,
        tolerance: SchedulerTimeType.Stride,
        options: Never?,
        _ action: @escaping () -> Void
    ) {
        scheduledActions.append(action)
    }

    func schedule(
        after date: SchedulerTimeType,
        interval: SchedulerTimeType.Stride,
        tolerance: SchedulerTimeType.Stride,
        options: Never?,
        _ action: @escaping () -> Void
    ) -> Cancellable {
        scheduledActions.append(action)
        return AnyCancellable {}
    }
}
