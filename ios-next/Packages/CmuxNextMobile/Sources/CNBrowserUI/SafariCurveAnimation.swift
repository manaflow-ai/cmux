#if os(iOS)
import SwiftUI

/// Replays a `SafariCurve` as a SwiftUI animation (the property follows
/// Safari's own per-frame progress instead of a fitted spring).
struct SafariCurveAnimation: CustomAnimation {
    let curve: SafariCurve
    /// Seconds the curve is advanced by, for a motion whose trigger reaches
    /// us later than Safari's (the slow release: one frame, measured).
    var lead: Double = 0

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        // The first frame on screen shows one 60 Hz frame of the curve,
        // however long the frame that made the change took: a close that
        // rebuilt the grid drew its first reflow frame two frames in (a 34 pt
        // jump). Any gap over one frame between the first calls is taken
        // out of the curve's clock.
        var clock = context.state[ClockKey.self] ?? Clock(shift: max(0, time - 1.0 / 60), last: time, calls: 0)
        if clock.calls > 0, clock.calls < 3, time - clock.last > 1.5 / 60 {
            clock.shift += time - clock.last - 1.0 / 60
        }
        clock.last = time
        clock.calls += 1
        context.state[ClockKey.self] = clock
        let t = time - clock.shift + lead
        guard t < curve.duration else { return nil }
        return value.scaled(by: curve.value(at: t))
    }

    private struct Clock {
        var shift: Double
        var last: Double
        var calls: Int
    }

    private struct ClockKey: AnimationStateKey {
        static var defaultValue: Clock? { nil }
    }
}

extension Animation {
    static func safari(_ curve: SafariCurve, lead: Double = 0) -> Animation {
        Animation(SafariCurveAnimation(curve: curve, lead: lead))
    }
}
#endif
