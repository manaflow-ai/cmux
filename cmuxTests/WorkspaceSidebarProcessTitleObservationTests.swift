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
        #expect(schedulers.allSatisfy { $0.scheduledActionCount == 6 })

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

        #expect(scheduler.scheduledActionCount == 16)
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

    @Test func customTitleCancelsPendingProcessTitleRefresh() {
        let scheduler = ManualProcessTitleSettleScheduler()
        let model = WorkspaceSidebarProcessTitleObservationModel(schedule: scheduler.schedule(delay:action:))
        let workspace = Workspace(sidebarProcessTitleObservation: model)
        let observationStream = model.changes()

        workspace.applyProcessTitle("Agent frame")
        #expect(scheduler.scheduledActionCount == 1)
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
