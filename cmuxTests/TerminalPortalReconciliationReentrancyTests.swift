import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct TerminalPortalReconciliationReentrancyTests {
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
