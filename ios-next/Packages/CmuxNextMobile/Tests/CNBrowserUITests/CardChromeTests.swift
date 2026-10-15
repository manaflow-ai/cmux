@testable import CNBrowserUI
import Testing

/// Safari's close-button and title timing (validation/browser.md rounds 10 and 11).
struct CardChromeTests {
    /// Opening: titles start at `titleTrigger` (0.90, sooner than Safari's
    /// 0.96 on purpose), the other close buttons at 0.96; then titles
    /// e^(-t/58 ms) and close buttons 16 ms later e^(-t/45 ms), Safari's
    /// measured curves within 0.05.
    @Test func opensOnItsOwnClockAfterTheTriggers() {
        #expect(CardChrome.titleTrigger == 0.90 && CardChrome.closeTrigger == 0.96)
        var c = CardChrome()
        c.step(1 / 60, progress: 0.85, headingToOverview: true, settledOnOverview: false)
        #expect(c.titleOpacity == 0 && c.closeOpacity == 0)
        // 0.90: the titles start, the close buttons do not.
        c.step(1 / 60, progress: 0.90, headingToOverview: true, settledOnOverview: false)
        #expect(c.titleOpacity == 0 && c.closeOpacity == 0)
        var title: [Double] = []
        for _ in 0..<3 {
            c.step(1 / 60, progress: 0.93, headingToOverview: true, settledOnOverview: false)
            title.append(c.titleOpacity)
            #expect(c.closeOpacity == 0)
        }
        // Device title curve: +17 ms .26, +33 .47, +50 .62
        #expect(abs(title[0] - 0.26) < 0.05)
        #expect(abs(title[1] - 0.47) < 0.05)
        #expect(abs(title[2] - 0.62) < 0.05)
        // 0.96: the close buttons start.
        c.step(1 / 60, progress: 0.96, headingToOverview: true, settledOnOverview: false)
        #expect(c.closeOpacity == 0)
        var close: [Double] = []
        for _ in 0..<10 {
            c.step(1 / 60, progress: 0.99, headingToOverview: true, settledOnOverview: false)
            close.append(c.closeOpacity)
        }
        // Device close: +33 ms .25, +50 .51, +150 .90
        #expect(abs(close[1] - 0.30) < 0.08)
        #expect(abs(close[2] - 0.51) < 0.08)
        #expect(abs(close[8] - 0.92) < 0.05)
        #expect(c.titleOpacity > 0.95 && c.titleOffset < 0.1)
    }

    /// A pinch that backs off below 0.90 hides the titles again.
    @Test func backingOffBelowTheTriggerHides() {
        var c = CardChrome()
        for _ in 0..<4 { c.step(1 / 60, progress: 0.92, headingToOverview: true, settledOnOverview: false) }
        #expect(c.titleOpacity > 0.3)
        c.step(1 / 60, progress: 0.85, headingToOverview: true, settledOnOverview: false)
        c.step(1 / 60, progress: 0.85, headingToOverview: true, settledOnOverview: false)
        #expect(c.titleOpacity == 0)
    }

    /// Leaving the grid: gone within two frames, from wherever it was.
    @Test func leavingHidesAtOnce() {
        var c = CardChrome()
        c.settle(onOverview: true)
        #expect(c.titleOpacity > 0.99)
        c.step(1 / 60, progress: 0.92, headingToOverview: false, settledOnOverview: false)
        #expect(c.titleOpacity > 0.45 && c.titleOpacity < 0.55)
        c.step(1 / 60, progress: 0.8, headingToOverview: false, settledOnOverview: false)
        #expect(c.titleOpacity == 0 && c.closeOpacity == 0)
        #expect(!c.animating)
    }

    /// The zooming card's close button follows progress (0.76 -> 0.96) and
    /// only toward the grid.
    @Test func zoomingCardCloseFollowsProgress() {
        #expect(CardChrome.zoomCloseOpacity(progress: 0.76, headingToOverview: true) == 0)
        #expect(abs(CardChrome.zoomCloseOpacity(progress: 0.82, headingToOverview: true) - 0.30) < 0.05)
        #expect(abs(CardChrome.zoomCloseOpacity(progress: 0.92, headingToOverview: true) - 0.80) < 0.05)
        #expect(CardChrome.zoomCloseOpacity(progress: 0.99, headingToOverview: true) == 1)
        #expect(CardChrome.zoomCloseOpacity(progress: 0.99, headingToOverview: false) == 0)
    }
}
