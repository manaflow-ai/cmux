import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for high-resolution mice (e.g. Logitech free-spin
/// wheels) being double-amplified in the terminal. Such mice report precise
/// scrolling deltas like a trackpad but carry no gesture phase, so the 2x boost
/// must not apply to them.
@Suite
struct GhosttyScrollPreciseBoostTests {
    @Test
    func trackpadGesturePhaseGetsBoost() {
        #expect(
            GhosttyTerminalScrollBoost(
                hasPreciseScrollingDeltas: true,
                phase: .changed,
                momentumPhase: []
            ).shouldDoublePreciseScrollDelta
        )
    }

    @Test
    func trackpadMomentumPhaseGetsBoost() {
        #expect(
            GhosttyTerminalScrollBoost(
                hasPreciseScrollingDeltas: true,
                phase: [],
                momentumPhase: .changed
            ).shouldDoublePreciseScrollDelta
        )
    }

    @Test
    func highResMouseWithoutPhaseIsNotBoosted() {
        // Logitech free-spin wheel: precise deltas, no phase, no momentum.
        #expect(
            !GhosttyTerminalScrollBoost(
                hasPreciseScrollingDeltas: true,
                phase: [],
                momentumPhase: []
            ).shouldDoublePreciseScrollDelta
        )
    }

    @Test
    func notchedMouseIsNotBoosted() {
        #expect(
            !GhosttyTerminalScrollBoost(
                hasPreciseScrollingDeltas: false,
                phase: [],
                momentumPhase: []
            ).shouldDoublePreciseScrollDelta
        )
    }

    @Test
    func scrollSpeedUsesAnExplicitlyUpdatedSnapshot() {
        let accumulator = TerminalScrollSpeedAccumulator(multiplier: 2)
        var x: CGFloat = 2
        var y: CGFloat = -3

        accumulator.apply(x: &x, y: &y, precision: true)
        #expect(x == 4)
        #expect(y == -6)

        accumulator.updateMultiplier(0.5)
        x = 2
        y = -3
        accumulator.apply(x: &x, y: &y, precision: true)
        #expect(x == 1)
        #expect(y == -1.5)
    }
}
