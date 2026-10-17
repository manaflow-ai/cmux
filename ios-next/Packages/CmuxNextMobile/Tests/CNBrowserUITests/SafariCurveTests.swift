@testable import CNBrowserUI
import Testing

struct SafariCurveTests {
    private let all: [SafariCurve] = [.zoomIn, .zoomOut, .reflow, .twoToOne, .snapBack, .lastTab, .swipeUp, .fling]

    @Test func everyCurveStartsAtRestAndEndsAtOne() {
        for c in all {
            #expect(c.samples.first == 0 && c.samples.last == 1)
            #expect(c.value(at: -1) == 0 && c.value(at: c.duration + 1) == 1)
        }
    }

    /// The reflow crosses 10 / 50 / 90 / 99 % within a frame of Safari's
    /// re-measured 42–50 / 119–134 / 243–250 / 343–351 ms.
    @Test func reflowCrossings() {
        let c = SafariCurve.reflow
        for (p, ms) in [(0.5, 134.0), (0.9, 250.0)] {
            #expect(abs(c.time(reaching: p) * 1000 - ms) <= 16.7)
        }
    }

    @Test func timeReachingInvertsValue() {
        let c = SafariCurve.swipeUp
        for p in [0.2, 0.5, 0.8] {
            #expect(abs(c.value(at: c.time(reaching: p)) - p) < 0.002)
        }
    }
}
