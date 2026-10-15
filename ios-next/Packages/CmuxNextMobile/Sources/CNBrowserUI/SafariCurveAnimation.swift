#if os(iOS)
import SwiftUI

/// Replays a `SafariCurve` as a SwiftUI animation (the property follows
/// Safari's own per-frame progress instead of a fitted spring).
struct SafariCurveAnimation: CustomAnimation {
    let curve: SafariCurve

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time < curve.duration else { return nil }
        return value.scaled(by: curve.value(at: time))
    }
}

extension Animation {
    static func safari(_ curve: SafariCurve) -> Animation { Animation(SafariCurveAnimation(curve: curve)) }
}
#endif
