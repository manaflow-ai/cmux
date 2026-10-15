import CoreGraphics

/// A drag on the bottom bar: sideways switches tabs, up opens the tab grid
/// (Safari's Compact layout), following the finger.
///
/// Safari (tabs-parity-audit 1d, `1-zoom/out-swipe.png`): the page follows a
/// swipe up steeply, about 0.67 of the way to its card when the finger
/// lifts, then springs to the grid (t99 390–442 ms).
struct BarSwipe: Equatable, Sendable {
    enum Axis: Equatable, Sendable { case horizontal, up, down }

    /// Safari's page follows the swipe along its swipe-up curve: a 250 pt
    /// swipe over 0.25 s (1000 pt/s) takes it through the curve's first
    /// 0.25 s, so the finger's travel maps to curve time at that speed.
    static let referenceSpeed: CGFloat = 1000

    /// The drag's direction from its first movement past the slop.
    static func axis(_ translation: CGSize) -> Axis {
        if abs(translation.width) > abs(translation.height) { return .horizontal }
        return translation.height < 0 ? .up : .down
    }

    /// The page's speed when the finger lifts outside the curve (a swipe
    /// back down): the finger's speed over the page-to-card travel.
    static func releaseVelocity(_ velocity: CGFloat) -> Double { Double(velocity) / 450 }

    /// Zoom progress (0 page, 1 grid) for an upward translation.
    static func progress(up: CGFloat) -> Double { SafariCurve.swipeUp.value(at: Double(max(0, up) / referenceSpeed)) }
    /// Progress per second for an upward velocity at `up`.
    static func velocity(up: CGFloat, velocity: CGFloat) -> Double {
        let t = Double(max(0, up) / referenceSpeed)
        let dp = SafariCurve.swipeUp.value(at: t + 1.0 / 120) - SafariCurve.swipeUp.value(at: t)
        return dp * 120 * Double(velocity / referenceSpeed)
    }
}
