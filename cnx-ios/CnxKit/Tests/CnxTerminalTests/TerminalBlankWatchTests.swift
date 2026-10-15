@testable import CnxTerminal
import Testing

/// VERIFY-round6 V6-2/3/4: a black page lasting seconds, until a touch.
@Suite struct TerminalBlankWatchTests {
    @Test func coverageComparesTheVisibleRowsWithTheFrame() {
        // Following at the cap after a prune: the frame was placed at 17590,
        // the page shows rows 16815..<16854.
        #expect(!TerminalBlankWatch.covers(presentedTop: 17590, surfaceRows: 151, visibleTop: 16815, visibleBottom: 16854,
                                           documentRows: 0..<16854))
        #expect(TerminalBlankWatch.covers(presentedTop: 16703, surfaceRows: 151, visibleTop: 16815, visibleBottom: 16854,
                                          documentRows: 0..<16854))
        // Rows past the document's end are the page's own blank.
        #expect(TerminalBlankWatch.covers(presentedTop: 0, surfaceRows: 151, visibleTop: 0, visibleBottom: 400,
                                          documentRows: 0..<20))
    }

    @Test func aStretchPastTheDeadlineAsksForARecoveryAndAgainUntilCovered() {
        var watch = TerminalBlankWatch()
        do { let r = watch.observe(covered: false, now: 10.0); #expect(!r) }
        do { let r = watch.observe(covered: false, now: 10.2); #expect(!r) }
        do { let r = watch.observe(covered: false, now: 10.26); #expect(r) }
        #expect(watch.events == 1)
        do { let r = watch.observe(covered: false, now: 10.3); #expect(!r) }
        do { let r = watch.observe(covered: false, now: 10.52); #expect(r) }
        #expect(watch.events == 1)
        do { let r = watch.observe(covered: true, now: 10.6); #expect(!r) }
        #expect(abs(watch.longest - 0.6) < 0.001)
        // A short gap (a frame in flight) is not an event.
        do { let r = watch.observe(covered: false, now: 11.0); #expect(!r) }
        do { let r = watch.observe(covered: true, now: 11.05); #expect(!r) }
        #expect(watch.events == 1)
    }
}
