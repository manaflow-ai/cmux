@testable import CNBrowserUI
import CoreGraphics
import Testing

struct BarSwipeTests {
    @Test func axisFromTheFirstMovement() {
        #expect(BarSwipe.axis(CGSize(width: 20, height: -5)) == .horizontal)
        #expect(BarSwipe.axis(CGSize(width: -4, height: -20)) == .up)
        #expect(BarSwipe.axis(CGSize(width: 2, height: 15)) == .down)
    }

    /// Safari's 270 pt / 0.2 s swipe (1350 pt/s): progress at 17-110 ms.
    @Test func followsTheFingerLikeSafari() {
        let safari: [(ms: Double, p: Double)] = [(17, 0.20), (33, 0.43), (50, 0.50), (70, 0.58), (90, 0.64), (110, 0.67)]
        for s in safari {
            let up = CGFloat(1350 * s.ms / 1000)
            #expect(abs(BarSwipe.progress(up: up) - s.p) < 0.06, "\(s.ms) ms")
        }
        #expect(BarSwipe.progress(up: 0) == 0)
    }
}
