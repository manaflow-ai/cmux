import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct InvalidationBatchingBehaviorTests {
    @Test func focusNotificationsCoalesceAtQuietDeadline() {
        let center = NotificationCenter()
        let scheduler = VirtualInvalidationDeadlineScheduler()
        let invalidator = FocusHistoryMenuInvalidator(
            center: center,
            scheduler: scheduler.schedule
        )

        for _ in 0..<99 {
            center.post(name: .tabManagerFocusHistoryRevisionDidChange, object: nil)
        }
        center.post(name: NSWindow.didBecomeKeyNotification, object: nil)

        #expect(invalidator.revision == 0)
        scheduler.advance(by: 0.039)
        #expect(invalidator.revision == 0)
        scheduler.advance(by: 0.002)
        #expect(invalidator.revision == 1)
        #expect(scheduler.activeDeadlineCount == 0)
    }

    @Test func sustainedFocusNotificationsDrainAtMaximumDeadline() {
        let center = NotificationCenter()
        let scheduler = VirtualInvalidationDeadlineScheduler()
        let invalidator = FocusHistoryMenuInvalidator(
            center: center,
            scheduler: scheduler.schedule
        )

        center.post(name: .tabManagerFocusHistoryRevisionDidChange, object: nil)
        for _ in 0..<3 {
            scheduler.advance(by: 0.03)
            center.post(name: .tabManagerFocusHistoryRevisionDidChange, object: nil)
        }
        scheduler.advance(by: 0.029)
        center.post(name: NSWindow.didBecomeKeyNotification, object: nil)

        #expect(invalidator.revision == 0)
        scheduler.advance(by: 0.002)
        #expect(invalidator.revision == 1)
        #expect(scheduler.activeDeadlineCount == 0)
    }

    @Test func mobileWorkspaceBurstDrainsOnceWithFinalStateAtQuietDeadline() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let scheduler = VirtualInvalidationDeadlineScheduler()
        var emittedTitles: [String] = []
        let observer = MobileWorkspaceListObserver(
            tabManager: manager,
            focusEventSequenceService: MobileWorkspaceFocusEventSequenceService(),
            scheduler: scheduler.schedule,
            emitWorkspaceUpdated: { emittedTitles.append(workspace.title) }
        )
        defer { withExtendedLifetime(observer) {} }

        settleInitialObserverBatch(
            scheduler: scheduler,
            emittedTitles: &emittedTitles
        )
        let metrics = MobileWorkspaceObserverMetrics.shared
        metrics.reset(enable: true)
        defer { metrics.reset(enable: false) }

        for index in 0..<100 {
            workspace.title = "Burst \(index)"
        }

        scheduler.advance(by: 0.049)
        #expect(emittedTitles.isEmpty)
        #expect(metrics.snapshot().batchDrains == 0)
        scheduler.advance(by: 0.002)

        #expect(emittedTitles == ["Burst 99"])
        assertMobileTitleBurstMetrics(metrics.snapshot(), submitted: 100)
        #expect(scheduler.activeDeadlineCount == 0)
    }

    @Test func sustainedMobileWorkspaceMutationsDrainOnceWithFinalStateAtMaximumDeadline() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let scheduler = VirtualInvalidationDeadlineScheduler()
        var emittedTitles: [String] = []
        let observer = MobileWorkspaceListObserver(
            tabManager: manager,
            focusEventSequenceService: MobileWorkspaceFocusEventSequenceService(),
            scheduler: scheduler.schedule,
            emitWorkspaceUpdated: { emittedTitles.append(workspace.title) }
        )
        defer { withExtendedLifetime(observer) {} }

        settleInitialObserverBatch(
            scheduler: scheduler,
            emittedTitles: &emittedTitles
        )
        let metrics = MobileWorkspaceObserverMetrics.shared
        metrics.reset(enable: true)
        defer { metrics.reset(enable: false) }

        workspace.title = "Sustained 0"
        for index in 1...4 {
            scheduler.advance(by: 0.039)
            workspace.title = "Sustained \(index)"
        }

        #expect(emittedTitles.isEmpty)
        #expect(metrics.snapshot().batchDrains == 0)
        scheduler.advance(by: 0.005)

        #expect(emittedTitles == ["Sustained 4"])
        assertMobileTitleBurstMetrics(metrics.snapshot(), submitted: 5)
        #expect(scheduler.activeDeadlineCount == 0)
    }

    private func settleInitialObserverBatch(
        scheduler: VirtualInvalidationDeadlineScheduler,
        emittedTitles: inout [String]
    ) {
        scheduler.advance(by: 1)
        emittedTitles.removeAll()
        #expect(scheduler.activeDeadlineCount == 0)
    }

    private func assertMobileTitleBurstMetrics(
        _ snapshot: MobileWorkspaceObserverMetricsSnapshot,
        submitted: Int
    ) {
        #expect(snapshot.enabled)
        #expect(snapshot.invalidationsSubmitted == [
            "workspace_graph": 0,
            "workspace": submitted,
            "preview": 0,
            "summary": 0,
        ])
        #expect(snapshot.batchDrains == 1)
        #expect(snapshot.invalidationsDrained == 1)
        #expect(snapshot.workspacesRehashed == 1)
        #expect(snapshot.emits == 1)
        #expect(snapshot.skips == 0)
        #expect(snapshot.fullGraphRebuilds == 0)
    }
}

@MainActor
private final class VirtualInvalidationDeadlineScheduler {
    typealias Cancellation = @MainActor () -> Void

    private struct ScheduledAction {
        let id: Int
        let deadline: TimeInterval
        let insertionOrder: Int
        let action: @MainActor () -> Void
    }

    private var now: TimeInterval = 0
    private var nextID = 0
    private var scheduled: [ScheduledAction] = []
    private var cancelled: Set<Int> = []

    var activeDeadlineCount: Int {
        scheduled.count { !cancelled.contains($0.id) }
    }

    func schedule(
        delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> Cancellation {
        nextID += 1
        let id = nextID
        scheduled.append(ScheduledAction(
            id: id,
            deadline: now + max(0, delay),
            insertionOrder: id,
            action: action
        ))
        return { [weak self] in
            self?.cancelled.insert(id)
        }
    }

    func advance(by delta: TimeInterval) {
        let target = now + max(0, delta)
        while let next = scheduled
            .filter({ !cancelled.contains($0.id) && $0.deadline <= target })
            .min(by: {
                ($0.deadline, $0.insertionOrder) < ($1.deadline, $1.insertionOrder)
            }) {
            scheduled.removeAll { $0.id == next.id }
            now = next.deadline
            next.action()
        }
        now = target
        scheduled.removeAll { cancelled.contains($0.id) }
    }
}
