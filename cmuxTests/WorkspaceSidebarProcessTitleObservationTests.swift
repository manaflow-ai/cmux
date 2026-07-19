import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceSidebarProcessTitleObservationTests {
    @Test func runtimePublicationPrunesTerminatedObservationBurst() {
        let model = WorkspaceSidebarAgentRuntimeObservationModel()
        var observations = (0..<2_000).map { _ in model.changes() }

        #expect(model.changeObservers.count == observations.count)
        observations.removeAll()

        model.setAgentPIDs(["codex": 42])

        #expect(
            model.changeObservers.count == 0,
            "A runtime change must reconcile terminated observers instead of retaining and revisiting them on every later event."
        )
    }

    @Test func processTitlePublicationPrunesTerminatedObservationBurst() {
        let scheduler = ManualProcessTitleSettleScheduler()
        let model = WorkspaceSidebarProcessTitleObservationModel(
            schedule: scheduler.schedule(delay:action:)
        )
        var observations = (0..<2_000).map { _ in model.changes() }

        #expect(model.changeObservers.count == observations.count)
        observations.removeAll()

        model.processTitleDidChange()
        scheduler.fireAll()

        #expect(
            model.changeObservers.count == 0,
            "A settled title publish must reconcile terminated observers instead of retaining and revisiting them on every later title."
        )
    }

    @Test func defersSustainedChurnUntilSettled() {
        let schedulers = (0..<16).map { _ in ManualProcessTitleSettleScheduler() }
        let models = schedulers.map { scheduler in
            WorkspaceSidebarProcessTitleObservationModel(schedule: scheduler.schedule(delay:action:))
        }
        let workspaces = models.map { model in
            Workspace(sidebarProcessTitleObservation: model)
        }
        let observationStreams = models.map { $0.changes() }
        var immediatePublishCounts = Array(repeating: 0, count: workspaces.count)
        let cancellables = workspaces.enumerated().map { index, workspace in
            workspace.sidebarImmediateObservationPublisher.sink {
                immediatePublishCounts[index] += 1
            }
        }
        defer { cancellables.forEach { $0.cancel() } }
        immediatePublishCounts = Array(repeating: 0, count: workspaces.count)

        for frame in 0..<6 {
            for (index, workspace) in workspaces.enumerated() {
                workspace.applyProcessTitle("Agent \(index) frame \(frame)")
            }
        }

        #expect(
            models.allSatisfy { $0.changeGeneration == 0 },
            "Process-title animation must not continuously invalidate sidebar rows while titles are still changing."
        )
        #expect(immediatePublishCounts.allSatisfy { $0 == 0 })
        #expect(schedulers.allSatisfy { scheduler in
            scheduler.scheduledActionCount(
                delay: WorkspaceSidebarProcessTitleObservationModel.defaultSettleInterval
            ) == 6
        })

        schedulers.forEach { $0.fireAll() }
        #expect(
            models.allSatisfy { $0.changeGeneration == 1 },
            "Each workspace must publish exactly one refresh with its settled process title."
        )
        withExtendedLifetime(observationStreams) {}
    }

    @Test func unobservedTitlesDoNotScheduleSettleActions() {
        let scheduler = ManualProcessTitleSettleScheduler()
        let model = WorkspaceSidebarProcessTitleObservationModel(schedule: scheduler.schedule(delay:action:))
        let workspace = Workspace(sidebarProcessTitleObservation: model)

        for frame in 0..<20 {
            workspace.applyProcessTitle("Agent frame \(frame)")
        }

        #expect(scheduler.scheduledActionCount == 0)
        #expect(model.changeGeneration == 0)
    }

    @Test func extensionAggregateCoalescesSettledWorkspaceChanges() {
        let scheduler = ManualProcessTitleSettleScheduler()
        let aggregate = WorkspaceSidebarProcessTitleObservationModel(
            settleInterval: WorkspaceSidebarProcessTitleObservationModel.extensionSidebarAggregateInterval,
            schedule: scheduler.schedule(delay:action:)
        )
        let observationStream = aggregate.changes()

        for _ in 0..<16 {
            aggregate.processTitleDidChange()
        }

        #expect(
            scheduler.scheduledActionCount(
                delay: WorkspaceSidebarProcessTitleObservationModel.extensionSidebarAggregateInterval
            ) == 16
        )
        #expect(aggregate.changeGeneration == 0)
        scheduler.fireAll()
        #expect(aggregate.changeGeneration == 1)
        withExtendedLifetime(observationStream) {}
    }

    @Test func sustainedChurnPublishesAtDeferralDeadline() {
        let scheduler = ManualProcessTitleSettleScheduler()
        let model = WorkspaceSidebarProcessTitleObservationModel(schedule: scheduler.schedule(delay:action:))
        let workspace = Workspace(sidebarProcessTitleObservation: model)
        let observationStream = model.changes()
        let settleDelay = WorkspaceSidebarProcessTitleObservationModel.defaultSettleInterval
        // The deferral policy contract: publication may lag churn by at most
        // four settle intervals (2 s for sidebar rows).
        let deferralDelay = settleDelay * 4

        // Sustained churn: every change lands inside the settle window, so
        // the settle timer alone never fires and the row would stay stale for
        // the whole animation (the 10 Hz title-animation hang workload).
        for frame in 0..<20 {
            workspace.applyProcessTitle("Agent frame \(frame)")
        }
        #expect(model.changeGeneration == 0)
        #expect(
            scheduler.scheduledActionCount(delay: deferralDelay) == 1,
            "A churn burst must arm exactly one non-resetting deferral deadline."
        )

        scheduler.fire(delay: deferralDelay)
        #expect(
            model.changeGeneration == 1,
            "Churn faster than the settle interval must still publish by the deferral deadline instead of starving the row."
        )

        // Churn continues: the next deferral window publishes again.
        workspace.applyProcessTitle("Agent frame 20")
        scheduler.fire(delay: deferralDelay)
        #expect(model.changeGeneration == 2)

        // Quiet after the last change: the settle timer delivers the final title.
        workspace.applyProcessTitle("Agent final")
        scheduler.fire(delay: settleDelay)
        #expect(model.changeGeneration == 3)
        withExtendedLifetime(observationStream) {}
    }

    @Test func singlePanelTitleUpdateSignalsSettleModel() throws {
        let scheduler = ManualProcessTitleSettleScheduler()
        let model = WorkspaceSidebarProcessTitleObservationModel(schedule: scheduler.schedule(delay:action:))
        let workspace = Workspace(sidebarProcessTitleObservation: model)
        let observationStream = model.changes()
        let panelId = try #require(workspace.focusedPanelId)

        // Terminal titles reach a single-panel workspace through
        // updatePanelTitle, which writes `title` directly (applyProcessTitle
        // then early-returns on `self.title != title`). The settle model must
        // still see the change, or sidebar rows never learn any automatic
        // title.
        _ = workspace.updatePanelTitle(panelId: panelId, title: "Agent tick 1")

        #expect(workspace.title == "Agent tick 1")
        #expect(
            scheduler.scheduledActionCount > 0,
            "A single-panel automatic title write must signal the sidebar settle model."
        )
        scheduler.fireAll()
        #expect(model.changeGeneration == 1)
        withExtendedLifetime(observationStream) {}
    }

    @Test func changeBeforeSubscriptionReplaysToNewObserver() {
        let scheduler = ManualProcessTitleSettleScheduler()
        let model = WorkspaceSidebarProcessTitleObservationModel(schedule: scheduler.schedule(delay:action:))
        let workspace = Workspace(sidebarProcessTitleObservation: model)

        // A row's onAppear snapshot and its .task stream subscription are not
        // atomic: a title change landing in that gap has no observers and must
        // not be lost, or a row whose title never changes again stays stale.
        workspace.applyProcessTitle("Agent title")
        #expect(scheduler.scheduledActionCount == 0)
        #expect(model.changeGeneration == 0)

        let observationStream = model.changes()
        #expect(
            model.changeGeneration == 1,
            "Subscribing after an unobserved title change must replay one refresh."
        )
        withExtendedLifetime(observationStream) {}
    }

    @Test func pendingChangeSurvivesLastObserverTeardown() async {
        let scheduler = ManualProcessTitleSettleScheduler()
        let model = WorkspaceSidebarProcessTitleObservationModel(schedule: scheduler.schedule(delay:action:))
        let workspace = Workspace(sidebarProcessTitleObservation: model)

        // Row replacement: the outgoing row is still subscribed when the
        // title changes, then tears down before the settle fires. The pending
        // change must survive as unobserved so the incoming row replays it.
        do {
            let outgoing = model.changes()
            workspace.applyProcessTitle("Agent title")
            #expect(scheduler.scheduledActionCount > 0)
            withExtendedLifetime(outgoing) {}
        }
        // The termination cleanup hops through a MainActor task; let it run.
        for _ in 0..<20 {
            await Task.yield()
        }

        let incoming = model.changes()
        #expect(
            model.changeGeneration == 1,
            "A change pending at last-observer teardown must replay to the next subscriber."
        )
        withExtendedLifetime(incoming) {}
    }

    @Test func settleFiringIntoCancelledContinuationRetainsChange() async {
        let scheduler = ManualProcessTitleSettleScheduler()
        let model = WorkspaceSidebarProcessTitleObservationModel(schedule: scheduler.schedule(delay:action:))
        let workspace = Workspace(sidebarProcessTitleObservation: model)

        // Row replacement can terminate a continuation while its entry is
        // still registered (the dictionary cleanup hops through a MainActor
        // task). A settle firing in that window yields .terminated; the
        // change must be retained for the next subscriber, not treated as
        // delivered.
        var outgoing: AsyncStream<Void>? = model.changes()
        workspace.applyProcessTitle("Agent title")
        #expect(scheduler.scheduledActionCount > 0)
        outgoing = nil
        scheduler.fireAll()
        #expect(
            model.changeGeneration == 0,
            "A settle that reached only terminated continuations delivered nothing."
        )

        for _ in 0..<20 {
            await Task.yield()
        }
        let incoming = model.changes()
        #expect(
            model.changeGeneration == 1,
            "The undelivered settle must replay to the next subscriber."
        )
        withExtendedLifetime(incoming) {}
        _ = outgoing
    }

    @Test func customTitleCancelsPendingProcessTitleRefresh() {
        let scheduler = ManualProcessTitleSettleScheduler()
        let model = WorkspaceSidebarProcessTitleObservationModel(schedule: scheduler.schedule(delay:action:))
        let workspace = Workspace(sidebarProcessTitleObservation: model)
        let observationStream = model.changes()

        workspace.applyProcessTitle("Agent frame")
        #expect(
            scheduler.scheduledActionCount(
                delay: WorkspaceSidebarProcessTitleObservationModel.defaultSettleInterval
            ) == 1
        )
        workspace.setCustomTitle("User Edit")
        scheduler.fireAll()

        #expect(model.changeGeneration == 0)
        #expect(workspace.title == "User Edit")
        withExtendedLifetime(observationStream) {}
    }
}

@MainActor
private final class ManualProcessTitleSettleScheduler {
    private struct PendingAction {
        var isCancelled = false
        var hasFired = false
        let delay: TimeInterval
        let action: @MainActor () -> Void
    }

    private var pendingActions: [PendingAction] = []
    var scheduledActionCount: Int { pendingActions.count }

    func scheduledActionCount(delay: TimeInterval) -> Int {
        pendingActions.filter { $0.delay == delay }.count
    }

    func schedule(
        delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> WorkspaceSidebarProcessTitleObservationModel.Cancellation {
        let index = pendingActions.count
        pendingActions.append(PendingAction(delay: delay, action: action))
        return { [weak self] in
            self?.pendingActions[index].isCancelled = true
        }
    }

    func fireAll() {
        fire { _ in true }
    }

    func fire(delay: TimeInterval) {
        fire { $0 == delay }
    }

    // Re-reads cancellation state per action: a fired publication cancels its
    // sibling deadline, which must then stay silent within the same pass.
    private func fire(_ matchesDelay: (TimeInterval) -> Bool) {
        for index in pendingActions.indices {
            guard !pendingActions[index].isCancelled,
                  !pendingActions[index].hasFired,
                  matchesDelay(pendingActions[index].delay) else { continue }
            pendingActions[index].hasFired = true
            pendingActions[index].action()
        }
    }
}
