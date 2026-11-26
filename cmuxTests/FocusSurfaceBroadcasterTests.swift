import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the focus-broadcast re-entrancy loop (issue #8843).
///
/// Production symptom: `Workspace.applyTabSelectionNow` posted
/// `.ghosttyDidFocusSurface` *synchronously* while `@Published` selection state was
/// mid-mutation. The Combine `.onReceive` subscriber in `ContentView` received it on
/// the posting thread and synchronously re-entered the focus path
/// (`attemptCommandPaletteFocusRestoreIfNeeded` -> `TabManager.focusTab` ->
/// `Workspace.focusPanel` -> `applyTabSelectionNow` -> post again). The only guard
/// (`Workspace.isApplyingTabSelection`) is per-instance, so a cycle that bounced
/// through SwiftUI body re-evaluation and across workspace instances was unbounded,
/// matching the hours-long SwiftUI/AppKit layout loop in issue #8843.
///
/// ``FocusSurfaceBroadcaster`` is the fix seam: emitting a focus broadcast is now
/// deferred + coalesced, same-transaction feedback is bounded across scheduler turns,
/// and a re-entrant emit during delivery is drained in a bounded loop instead of
/// recursing. These tests exercise that contract directly, without AppKit, by
/// injecting a manual scheduler and capturing deliveries.
@MainActor
@Suite("Focus surface broadcaster re-entrancy")
struct FocusSurfaceBroadcasterTests {

    private static func payload(
        _ seed: Int,
        transactionId: UUID = UUID()
    ) -> FocusSurfaceBroadcaster.FocusSurfacePayload {
        FocusSurfaceBroadcaster.FocusSurfacePayload(
            workspaceId: UUID(),
            panelId: UUID(),
            explicitFocusIntent: seed.isMultiple(of: 2),
            transactionId: transactionId
        )
    }

    /// Deterministic stand-in for `DispatchQueue.main.async`: captured flush closures
    /// are stored and run on demand so the test controls runloop turns.
    @MainActor
    private final class ManualScheduler {
        private(set) var pending: [@MainActor @Sendable () -> Void] = []

        func append(_ work: @escaping @MainActor @Sendable () -> Void) {
            pending.append(work)
        }

        var count: Int { pending.count }

        /// Runs every currently-queued flush. Clears the queue first so re-entrant
        /// scheduling during a run is observable via ``count``.
        func runAll() {
            let work = pending
            pending.removeAll()
            for unit in work { unit() }
        }
    }

    /// Safe because the relay is main-actor isolated and every captured test
    /// delivery closure is also `@MainActor`.
    @MainActor
    private final class BroadcasterRelay: @unchecked Sendable {
        var broadcaster: FocusSurfaceBroadcaster?

        func emit(_ payload: FocusSurfaceBroadcaster.FocusSurfacePayload) {
            broadcaster?.emit(payload)
        }
    }

    @Test("emit() defers delivery to a scheduled flush instead of firing synchronously")
    func emitDefersDeliveryUntilFlush() {
        let scheduler = ManualScheduler()
        var delivered: [FocusSurfaceBroadcaster.FocusSurfacePayload] = []
        let broadcaster = FocusSurfaceBroadcaster(
            schedule: { scheduler.append($0) },
            deliver: { delivered.append($0) }
        )

        let only = Self.payload(1)
        broadcaster.emit(only)

        // The whole point: nothing is delivered on the emit() call itself, so a
        // caller mutating @Published state is fully settled before observers run.
        #expect(delivered.isEmpty)
        #expect(scheduler.count == 1)

        scheduler.runAll()
        #expect(delivered == [only])
    }

    @Test("multiple emits before a flush coalesce to the latest payload")
    func coalescesEmitsBeforeFlush() {
        let scheduler = ManualScheduler()
        var delivered: [FocusSurfaceBroadcaster.FocusSurfacePayload] = []
        let broadcaster = FocusSurfaceBroadcaster(
            schedule: { scheduler.append($0) },
            deliver: { delivered.append($0) }
        )

        let first = Self.payload(1)
        let second = Self.payload(2)
        let third = Self.payload(3)
        broadcaster.emit(first)
        broadcaster.emit(second)
        broadcaster.emit(third)

        #expect(delivered.isEmpty)
        // Only one flush is scheduled no matter how many emits land in the same turn.
        #expect(scheduler.count == 1)

        scheduler.runAll()
        #expect(delivered == [third])
    }

    @Test("default delivery posts the focus transaction id")
    func defaultDeliveryPostsFocusTransactionId() {
        let scheduler = ManualScheduler()
        let transactionId = UUID()
        let payload = Self.payload(1, transactionId: transactionId)
        var postedUserInfo: [AnyHashable: Any]?
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID == payload.workspaceId,
                  notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID == payload.panelId else {
                return
            }
            postedUserInfo = notification.userInfo
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let broadcaster = FocusSurfaceBroadcaster(
            schedule: { scheduler.append($0) }
        )

        broadcaster.emit(payload)
        scheduler.runAll()

        #expect(postedUserInfo?[GhosttyNotificationKey.tabId] as? UUID == payload.workspaceId)
        #expect(postedUserInfo?[GhosttyNotificationKey.surfaceId] as? UUID == payload.panelId)
        #expect(postedUserInfo?[GhosttyNotificationKey.explicitFocusIntent] as? Bool == payload.explicitFocusIntent)
        #expect(postedUserInfo?[GhosttyNotificationKey.focusTransactionId] as? UUID == transactionId)
    }

    @Test("a re-entrant emit is bounded per turn, never recurses, and never hangs")
    func reentrantEmitIsBoundedPerTurn() {
        let scheduler = ManualScheduler()
        var delivered: [FocusSurfaceBroadcaster.FocusSurfacePayload] = []
        var boundExceeded: [FocusSurfaceBroadcaster.FocusSurfacePayload] = []
        let relay = BroadcasterRelay()
        let transactionId = UUID()
        let reentryTarget = Self.payload(99, transactionId: transactionId)
        // Simulates the .onReceive -> focusTab -> applyTabSelectionNow -> emit cycle:
        // every delivery re-focuses, far more often than the per-turn bound allows.
        var reentryBudget = 100

        let broadcaster = FocusSurfaceBroadcaster(
            maxCoalescedDeliveries: 8,
            maxConsecutiveBoundedFlushes: 1_000,
            schedule: { scheduler.append($0) },
            onDrainBoundExceeded: { boundExceeded.append($0) },
            deliver: { payload in
                delivered.append(payload)
                if reentryBudget > 0 {
                    reentryBudget -= 1
                    relay.emit(reentryTarget)
                }
            }
        )
        relay.broadcaster = broadcaster

        broadcaster.emit(Self.payload(0, transactionId: transactionId))

        // The first flush delivers at most the bound, then defers the rest instead
        // of recursing `reentryBudget` deep (the un-fixed behavior delivers 101 in a
        // single synchronous call).
        scheduler.runAll()
        #expect(delivered.count == 8)
        #expect(boundExceeded.count == 1)
        #expect(scheduler.count == 1)   // a continuation was scheduled, not dropped

        // Each subsequent turn also stays bounded; the cycle eventually drains.
        var turns = 1
        while scheduler.count > 0 {
            turns += 1
            #expect(turns < 1000)       // converges, not an infinite cross-turn loop
            if turns >= 1000 { break }
            let before = delivered.count
            scheduler.runAll()
            #expect(delivered.count - before <= 8)   // never more than the bound per turn
        }

        // Nothing was dropped: the initial focus plus all re-emits were delivered,
        // and the system settled on the final selection.
        #expect(delivered.count == 101)
        #expect(delivered.last == reentryTarget)
        #expect(reentryBudget == 0)
    }

    @Test("a converging re-entrant cycle settles on the final selection")
    func reentrantEmitConvergesToFinalSelection() {
        let scheduler = ManualScheduler()
        var delivered: [FocusSurfaceBroadcaster.FocusSurfacePayload] = []
        let relay = BroadcasterRelay()
        let transactionId = UUID()
        let finalTarget = Self.payload(7, transactionId: transactionId)
        // The observer re-focuses the same target a couple of times, then stops -
        // the realistic case where focus restore eventually converges.
        var reEmitsRemaining = 2

        let broadcaster = FocusSurfaceBroadcaster(
            maxCoalescedDeliveries: 8,
            schedule: { scheduler.append($0) },
            deliver: { payload in
                delivered.append(payload)
                if reEmitsRemaining > 0 {
                    reEmitsRemaining -= 1
                    relay.emit(finalTarget)
                }
            }
        )
        relay.broadcaster = broadcaster

        broadcaster.emit(Self.payload(0, transactionId: transactionId))
        scheduler.runAll()

        // Initial delivery + two convergent re-emits, then quiescent.
        #expect(delivered.count == 3)
        #expect(delivered.last == finalTarget)
        #expect(scheduler.count == 0)
    }

    @Test("a non-converging re-entrant cycle trips instead of rescheduling forever")
    func nonConvergingReentrantCycleTripsCircuitBreaker() {
        let scheduler = ManualScheduler()
        var delivered: [FocusSurfaceBroadcaster.FocusSurfacePayload] = []
        var boundExceeded: [FocusSurfaceBroadcaster.FocusSurfacePayload] = []
        var tripped: [FocusSurfaceBroadcaster.FocusSurfacePayload] = []
        let relay = BroadcasterRelay()
        let transactionId = UUID()
        let reentryTarget = Self.payload(8843, transactionId: transactionId)
        var reentryBudget = 1_000

        let broadcaster = FocusSurfaceBroadcaster(
            maxCoalescedDeliveries: 2,
            maxCircuitBreakerRecoveryDeliveries: 2,
            schedule: { scheduler.append($0) },
            onDrainBoundExceeded: { boundExceeded.append($0) },
            onCircuitBreakerTripped: { tripped.append($0) },
            deliver: { payload in
                delivered.append(payload)
                if reentryBudget > 0 {
                    reentryBudget -= 1
                    relay.emit(reentryTarget)
                }
            }
        )
        relay.broadcaster = broadcaster

        broadcaster.emit(Self.payload(0, transactionId: transactionId))

        var turns = 0
        while scheduler.count > 0 && turns < 12 {
            turns += 1
            scheduler.runAll()
        }

        #expect(
            scheduler.count == 0,
            "A self-sustaining focus cycle must not be able to enqueue immediate flushes forever."
        )
        #expect(
            turns == 6,
            "The circuit breaker plus recovery should stop after six turns, got \(turns)."
        )
        #expect(
            delivered.count == 10,
            "The cycle delivered \(delivered.count) focus broadcasts before stopping."
        )
        #expect(
            delivered.last == reentryTarget,
            "The drain should still settle on the latest requested focus payload."
        )
        #expect(
            boundExceeded.count == 4,
            "The cycle should exceed the per-turn bound four times before tripping; got \(boundExceeded.count)."
        )
        #expect(
            tripped == [reentryTarget],
            "The circuit breaker should report the final reconciled payload once."
        )
        #expect(
            reentryBudget > 0,
            "The test must stop because the circuit breaker tripped, not because the synthetic budget ran dry."
        )
    }

    @Test("same-transaction deferred feedback is bounded across scheduler turns")
    func sameTransactionDeferredFeedbackTripsAcrossTurns() {
        let scheduler = ManualScheduler()
        var delivered: [FocusSurfaceBroadcaster.FocusSurfacePayload] = []
        var tripped: [FocusSurfaceBroadcaster.FocusSurfacePayload] = []
        let relay = BroadcasterRelay()
        let transactionId = UUID()
        let initial = Self.payload(0, transactionId: transactionId)
        let feedback = Self.payload(7, transactionId: transactionId)
        var deferredFeedbackBudget = 1_000

        let broadcaster = FocusSurfaceBroadcaster(
            maxCoalescedDeliveries: 8,
            maxConsecutiveCircuitDeliveries: 3,
            maxCircuitBreakerRecoveryDeliveries: 2,
            schedule: { scheduler.append($0) },
            onCircuitBreakerTripped: { tripped.append($0) },
            deliver: { payload in
                delivered.append(payload)
                guard deferredFeedbackBudget > 0 else { return }
                deferredFeedbackBudget -= 1
                scheduler.append {
                    relay.emit(feedback)
                }
            }
        )
        relay.broadcaster = broadcaster

        broadcaster.emit(initial)

        var turns = 0
        while scheduler.count > 0 && turns < 20 {
            turns += 1
            scheduler.runAll()
        }

        #expect(scheduler.count == 0)
        #expect(turns == 11)
        #expect(delivered == [initial, feedback, feedback, feedback, feedback])
        #expect(tripped == [feedback])
        #expect(deferredFeedbackBudget > 0)
    }
}
