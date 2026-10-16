import Foundation
import CMUXMobileCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct TerminalPortalReconciliationReentrancyTests {
    @Test func bindingWorkDoesNotEstablishARevealTransition() {
        let scheduler = TerminalPortalReconciliationScheduler()
        var delivered: TerminalWorkContext.Transition?
        scheduler.stage(reasons: .bindingRequired) { request in
            delivered = request.transition
        }
        scheduler.flushPendingReconciliation()
        #expect(delivered == .unknown)
    }

    @Test(arguments: [TerminalWorkContext.Transition.split, .restore, .reveal, .resize])
    func coalescedCallbacksPreserveTheCapturedTransition(transition: TerminalWorkContext.Transition) {
        let scheduler = TerminalPortalReconciliationScheduler()
        var delivered: TerminalPortalReconciliationRequest?
        scheduler.stage(transition: transition) { _ in
            Issue.record("Only the latest reconciliation should run")
        }
        // Rebinding, geometry and host-move callbacks do not establish a new
        // origin. Their latest closure still needs the initiating transition.
        scheduler.stage(reasons: .bindingRequired) { _ in
            Issue.record("Only the latest reconciliation should run")
        }
        scheduler.stage(reasons: .flushPendingManualSizeReport) { delivered = $0 }
        scheduler.flushPendingReconciliation()
        #expect(delivered?.transition == transition)
        #expect(delivered?.reasons == [.bindingRequired, .flushPendingManualSizeReport])
    }

    @Test func aLaterExplicitTransitionSupersedesAnEarlierOrigin() {
        let scheduler = TerminalPortalReconciliationScheduler()
        var delivered: TerminalWorkContext.Transition?
        scheduler.stage(transition: .split) { _ in }
        scheduler.stage(transition: .resize) { _ in }
        scheduler.stage { delivered = $0.transition }
        scheduler.flushPendingReconciliation()
        #expect(delivered == .resize)
    }

    @Test func cancellationAndCompletionDoNotLeakAnEarlierTransition() {
        let scheduler = TerminalPortalReconciliationScheduler()
        var delivered: [TerminalWorkContext.Transition] = []
        scheduler.stage(transition: .restore) { _ in Issue.record("Cancelled work must not run") }
        scheduler.cancel()
        scheduler.stage { delivered.append($0.transition) }
        scheduler.flushPendingReconciliation()
        scheduler.stage(transition: .split) { delivered.append($0.transition) }
        scheduler.flushPendingReconciliation()
        scheduler.stage { delivered.append($0.transition) }
        scheduler.flushPendingReconciliation()
        #expect(delivered == [.unknown, .split, .unknown])
    }

    @Test func nestedFlushWaitsForTheActiveGeometryPass() {
        let scheduler = TerminalPortalReconciliationScheduler()
        var events: [String] = []
        var deliveredReasons: TerminalPortalReconciliationReasons = []
        scheduler.stage { _ in
            events.append("outer.begin")
            scheduler.stage(reasons: .bindingRequired) { _ in
                Issue.record("Superseded geometry must not be applied")
            }
            scheduler.stage(reasons: .flushPendingManualSizeReport) { reasons in
                deliveredReasons = reasons.reasons
                events.append("latest")
            }
            // AppKit can drain the run loop while applying a portal update.
            // Exercise the exact delivery boundary without needing a window
            // transaction or waiting for an eight-second production hang.
            scheduler.flushPendingReconciliation()
            events.append("outer.end")
        }

        scheduler.flushPendingReconciliation()
        #expect(events == ["outer.begin", "outer.end"])
        scheduler.flushPendingReconciliation()
        #expect(events == ["outer.begin", "outer.end", "latest"])
        #expect(deliveredReasons == [.bindingRequired, .flushPendingManualSizeReport])
        scheduler.flushPendingReconciliation()
        #expect(events.count == 3)
    }

    @Test func cancellationDuringTheActivePassDiscardsOnlyPendingWork() {
        let scheduler = TerminalPortalReconciliationScheduler()
        var events: [String] = []
        scheduler.stage { _ in
            events.append("outer.begin")
            scheduler.stage { _ in Issue.record("Cancelled work must not run") }
            scheduler.cancel()
            scheduler.stage { _ in events.append("replacement") }
            scheduler.flushPendingReconciliation()
            events.append("outer.end")
        }

        scheduler.flushPendingReconciliation()
        #expect(events == ["outer.begin", "outer.end"])
        scheduler.flushPendingReconciliation()
        #expect(events == ["outer.begin", "outer.end", "replacement"])
    }
}
