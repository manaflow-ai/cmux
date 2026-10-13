@testable import CNBrowserUI
import Testing

/// Safari's close-button and title timing (validation/browser.md round 10).
struct CardChromeTests {
    /// Opening: nothing until 0.96, then titles e^(-t/58 ms), close buttons
    /// 16 ms later e^(-t/45 ms); measured device values within 0.05.
    @Test func opensOnItsOwnClockAfterTheTrigger() {
        var c = CardChrome()
        c.step(1 / 60, progress: 0.9, headingToOverview: true, settledOnOverview: false)
        #expect(c.titleOpacity == 0 && c.closeOpacity == 0)
        c.step(1 / 60, progress: 0.96, headingToOverview: true, settledOnOverview: false)
        #expect(c.titleOpacity == 0)
        var measuredTitle: [Double] = []
        var measuredClose: [Double] = []
        for _ in 0..<10 {
            c.step(1 / 60, progress: 0.99, headingToOverview: true, settledOnOverview: false)
            measuredTitle.append(c.titleOpacity); measuredClose.append(c.closeOpacity)
        }
        // Device (neighbour title, close): +17 ms .20/.07, +33 .42/.25, +50 .61/.51, +100 .79/.79, +150 .91/.90
        #expect(abs(measuredTitle[1] - 0.40) < 0.05)
        #expect(abs(measuredTitle[5] - 0.79) < 0.05)
        #expect(abs(measuredTitle[8] - 0.91) < 0.05)
        #expect(abs(measuredClose[2] - 0.51) < 0.08)
        #expect(abs(measuredClose[8] - 0.92) < 0.05)
        #expect(c.titleOffset < 0.5)
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
