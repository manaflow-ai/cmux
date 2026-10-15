@testable import CNBrowserUI
import CoreGraphics
import Testing

struct BarSwipeTests {
    @Test func axisFromTheFirstMovement() {
        #expect(BarSwipe.axis(CGSize(width: 20, height: -5)) == .horizontal)
        #expect(BarSwipe.axis(CGSize(width: -4, height: -20)) == .up)
        #expect(BarSwipe.axis(CGSize(width: 2, height: 15)) == .down)
    }

    /// The page follows Safari's swipe-up curve at the reference speed.
    @Test func followsSafarisCurve() {
        for ms in [17.0, 50, 100, 200] {
            let up = CGFloat(BarSwipe.referenceSpeed * ms / 1000)
            #expect(abs(BarSwipe.progress(up: up) - SafariCurve.swipeUp.value(at: ms / 1000)) < 1e-9)
        }
        #expect(BarSwipe.progress(up: 0) == 0)
    }
}
