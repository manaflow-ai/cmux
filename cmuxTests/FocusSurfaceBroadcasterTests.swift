import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the focus-broadcast re-entrancy hang (issue #5100).
///
/// Production symptom: `Workspace.applyTabSelectionNow` posted
/// `.ghosttyDidFocusSurface` *synchronously* while Combine-backed selection state was
/// mid-mutation. The Combine `.onReceive` subscriber in `ContentView` received it on
/// the posting thread and synchronously re-entered the focus path
/// (`attemptCommandPaletteFocusRestoreIfNeeded` → `TabManager.focusTab` →
/// `Workspace.focusPanel` → `applyTabSelectionNow` → post again). The only guard
/// (`Workspace.isApplyingTabSelection`) is per-instance, so a cycle that bounced
/// through SwiftUI body re-evaluation and across workspace instances was unbounded —
/// a 426s main-thread hang.
///
/// ``FocusSurfaceBroadcaster`` is the fix seam: emitting a focus broadcast is now
/// deferred + coalesced and a re-entrant emit during delivery is drained in a bounded
/// loop instead of recursing. These tests exercise that contract directly, without
/// AppKit, by injecting a manual scheduler and capturing deliveries.
@MainActor
@Suite("Focus surface broadcaster re-entrancy")
struct FocusSurfaceBroadcasterTests {

    /// Distinct payloads; the `explicitFocusIntent` flag just varies for identity.
    private static func payload(_ seed: Int) -> FocusSurfaceBroadcaster.FocusSurfacePayload {
        FocusSurfaceBroadcaster.FocusSurfacePayload(
            workspaceId: UUID(),
            panelId: UUID(),
            explicitFocusIntent: seed.isMultiple(of: 2)
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
        // caller mutating state is fully settled before observers run.
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

    @Test("a re-entrant emit is bounded per turn, never recurses, and never hangs")
    func reentrantEmitIsBoundedPerTurn() {
        let scheduler = ManualScheduler()
        var delivered: [FocusSurfaceBroadcaster.FocusSurfacePayload] = []
        var boundExceeded: [FocusSurfaceBroadcaster.FocusSurfacePayload] = []
        var broadcaster: FocusSurfaceBroadcaster!
        let reentryTarget = Self.payload(99)
        // Simulates the .onReceive → focusTab → applyTabSelectionNow → emit cycle:
        // every delivery re-focuses, far more often than the per-turn bound allows.
        var reentryBudget = 100

        broadcaster = FocusSurfaceBroadcaster(
            maxCoalescedDeliveries: 8,
            schedule: { scheduler.append($0) },
            onDrainBoundExceeded: { boundExceeded.append($0) },
            deliver: { payload in
                delivered.append(payload)
                if reentryBudget > 0 {
                    reentryBudget -= 1
                    broadcaster.emit(reentryTarget)
                }
            }
        )

        broadcaster.emit(Self.payload(0))

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
            #expect(turns < 1000)       // converges — not an infinite cross-turn loop
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
        var broadcaster: FocusSurfaceBroadcaster!
        let finalTarget = Self.payload(7)
        // The observer re-focuses the same target a couple of times, then stops —
        // the realistic case where focus restore eventually converges.
        var reEmitsRemaining = 2

        broadcaster = FocusSurfaceBroadcaster(
            maxCoalescedDeliveries: 8,
            schedule: { scheduler.append($0) },
            deliver: { payload in
                delivered.append(payload)
                if reEmitsRemaining > 0 {
                    reEmitsRemaining -= 1
                    broadcaster.emit(finalTarget)
                }
            }
        )

        broadcaster.emit(Self.payload(0))
        scheduler.runAll()

        // Initial delivery + two convergent re-emits, then quiescent.
        #expect(delivered.count == 3)
        #expect(delivered.last == finalTarget)
        #expect(scheduler.count == 0)
    }
}
