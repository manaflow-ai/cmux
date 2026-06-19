import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for high-resolution mice (e.g. Logitech free-spin
/// wheels) being double-amplified in the terminal. Such mice report precise
/// scrolling deltas like a trackpad but carry no gesture phase, so the 2x boost
/// must not apply to them.
final class GhosttyScrollPreciseBoostTests: XCTestCase {
    func testTrackpadGesturePhaseGetsBoost() {
        XCTAssertTrue(
            GhosttyNSView.shouldDoublePreciseScrollDelta(
                hasPreciseScrollingDeltas: true,
                phase: .changed,
                momentumPhase: []
            )
        )
    }

    func testTrackpadMomentumPhaseGetsBoost() {
        XCTAssertTrue(
            GhosttyNSView.shouldDoublePreciseScrollDelta(
                hasPreciseScrollingDeltas: true,
                phase: [],
                momentumPhase: .changed
            )
        )
    }

    func testHighResMouseWithoutPhaseIsNotBoosted() {
        // Logitech free-spin wheel: precise deltas, no phase, no momentum.
        XCTAssertFalse(
            GhosttyNSView.shouldDoublePreciseScrollDelta(
                hasPreciseScrollingDeltas: true,
                phase: [],
                momentumPhase: []
            )
        )
    }

    func testNotchedMouseIsNotBoosted() {
        XCTAssertFalse(
            GhosttyNSView.shouldDoublePreciseScrollDelta(
                hasPreciseScrollingDeltas: false,
                phase: [],
                momentumPhase: []
            )
        )
    }
}
