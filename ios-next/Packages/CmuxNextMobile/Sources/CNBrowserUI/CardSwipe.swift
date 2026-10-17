import CoreGraphics

/// Swipe a grid card left to close it, as Safari does. Device reference:
/// iPhone 17 Pro Max Safari (`swipe-close-device.mp4`, real frame times,
/// validation/browser.md round 16); thresholds from simulator Safari trials
/// (round 14):
///
/// - Horizontal drags only (a mostly vertical drag scrolls the grid). The card
///   lifts (scale 1.093 over about 80 ms) as soon as it is dragged. Left
///   follows the finger from touch-down, gliding over the slop in 80 ms;
///   right is rubber-banded (100 pt gives 44 pt) and always springs back.
/// - No fade while dragging.
/// - Release closes when the card, projected 0.2 s ahead at its release
///   velocity, is at least 72% of its width to the left, or when the finger
///   leaves leftward faster than 225 pt/s; a drag that slows to a stop under
///   that springs back to its slot (0.56 / 0.92, right 0.75 / 0.81,
///   carrying the finger's velocity) and settles to scale 1 (0.57 / 0.94).
/// - Closing: the card keeps going left at the release speed (≥ 1000 pt/s),
///   lifted and opaque, from the release frame until it is off screen; its
///   tab leaves the grid at release without waiting for the host (a refused
///   close brings the card back). When one tab is left, Safari opens it.
struct CardSwipe: Equatable, Sendable {
    static let commitFraction: CGFloat = 0.72
    static let flingVelocity: CGFloat = 225
    /// Rightward rubber band: `d * (1 - 1 / (x * c / d + 1))`.
    static let rubberDimension: CGFloat = 120
    /// Safari: a 100 pt drag right (measured from touch-down) moves the card
    /// 44 pt (tabs-parity-audit 3f).
    static let rubberConstant: CGFloat = 0.695
    /// Spring back to the slot after a left drag (simulator Safari, from the
    /// turnaround: 0.562 / 0.918, tabs-parity-audit 3g). After a right drag
    /// the card replays Safari's own curve (`SafariCurve.snapBackRight`):
    /// the fitted 0.75 / 0.81 overshot 1.6 % and rested 50 ms early.
    static let snapBack = ZoomSpring(response: 0.56, damping: 0.92)
    /// The card lifts while it is dragged (Safari: 176 -> 192 pt, × 1.093,
    /// over about 80 ms, about its centre) and settles back on release
    /// (scale fit 0.57 / 0.94).
    static let liftScale: CGFloat = 1.093
    static let lift = ZoomSpring(response: 0.12, damping: 1)
    /// The card follows the finger on this spring (Safari's glide over the
    /// slop and its carry past a stopped finger, re-audit 3 D3).
    static let follow = ZoomSpring(response: 0.12, damping: 0.7)
    /// The card stays in its slot until the finger is this far out, then
    /// glides onto it: Safari's card starts later in a drag than a pan
    /// recognised at UIKit's slop (re-audit 4 D3: ours ran 13-15 pt behind
    /// Safari's track from its onset).
    static let onsetTravel: CGFloat = 19
    /// From there the card glides onto the finger over this long, easing out
    /// (1 - (1 - u)^2 of the finger's offset): Safari's card is at about
    /// 0.17 / 0.4 / 0.65 / 0.84 / 0.95 of the finger 8 / 20 / 37 / 52 / 70 ms
    /// in (re-audit 3 D3). A spring from rest there stepped by the display
    /// link's timestamps, and a late first tick made it jump 15-18 pt in
    /// one frame, or ran 9-12 pt behind (re-audit 5 D3).
    static let onsetGlide: Double = 0.1
    /// Leftward, the card runs this far ahead of the finger along its
    /// velocity (at most `leadMax`), like a predicted touch: Safari's card
    /// ends about 4 pt past a finger that stopped at 100 pt/s, and springs
    /// back from there.
    static let leadTime: CGFloat = 0.045
    static let leadMax: CGFloat = 8
    static let leadMaxSpeed: CGFloat = 300
    /// A finger leftward this fast, with the close rule already met, is a
    /// fling: the count changes on that tick, before the finger lifts (Safari's
    /// count changes 5-12 ms after a fling's finger end; ours waited for the
    /// lift's event, 40-57 ms).
    static let flingCountSpeed: CGFloat = 600
    /// Display-link ticks from that decision to the count: it read 24-28 ms
    /// ahead of Safari's at once (the finger is still moving); after 4 it
    /// changed a frame after the card's first move (19-26 ms, Safari 5-12),
    /// after 3 on that frame (+1 to +6 ms).
    static let flingCountTicks = 3
    /// The touch slop is caught up over this long once the drag is recognised.
    static let slopCatchUp = 0.08
    /// The lift's scale back to 1 on a spring back: fitted to Safari's
    /// (re-audit 3 3h, 50 / 150 / 283 ms; rms 0.011). 0.57 / 0.94 was
    /// 27-54 ms late at its crossings (re-audit 4).
    static let settle = ZoomSpring(response: 0.58, damping: 0.82)
    /// A closing card keeps going left at the finger's speed (device ≈ 1000
    /// pt/s, still lifted and opaque) until it is off screen.
    static let flyOffMinSpeed: CGFloat = 1000
    /// Fly-off time for `distance` points at the release speed (Safari
    /// carries it: about 1170 pt/s for a 100 pt / 0.12 s flick).
    static func flyOffDuration(distance: CGFloat, velocity: CGFloat) -> Double {
        Double(abs(distance) / max(abs(velocity), flyOffMinSpeed))
    }
    /// The tab leaves the grid at the release (Safari's count changes 5-12 ms
    /// after the finger ends; the card holds 2 frames meanwhile, as Safari's).
    static let flyOffRemovalDelay: Duration = .zero
    /// Reduce Motion: no movement after release, a crossfade instead.
    static let reduceMotionFade = 0.18

    /// The card's offset for a finger translation.
    static func offset(translation dx: CGFloat) -> CGFloat {
        guard dx > 0 else { return dx }
        let d = rubberDimension
        return d * (1 - 1 / (dx * rubberConstant / d + 1))
    }

    /// Close on release? `offset` and `velocity` in points (/s), negative
    /// left. The card's position projected `projectionTime` ahead at the
    /// release velocity must be past 72% of the width, or the finger must
    /// leave leftward faster than 225 pt/s.
    ///
    /// Measured on one simulator with Safari and the same AXe inputs on a
    /// 177 pt card (validation round 21): a 100 pt drag over 1.0 s that
    /// slows to a stop springs back 3 of 3 (UIKit reports about −70 pt/s at
    /// release); a 100 pt swipe over 1.0 s that leaves moving closes 2 of 2
    /// (about −190 pt/s). Projection 0.2 s separates them with margin
    /// (−115 against −138 for a −127 threshold) and keeps the earlier
    /// trials: held releases at −84 to −123 spring back, −132 closes, a
    /// 60 pt flick closes at 250 pt/s and not at 200.
    static let projectionTime: CGFloat = 0.2
    static func commits(offset: CGFloat, velocity: CGFloat, cardWidth: CGFloat) -> Bool {
        guard offset < 0, velocity < flingVelocity else { return false }
        let projected = offset + min(0, velocity) * projectionTime
        return projected <= -commitFraction * cardWidth || velocity <= -flingVelocity
    }

    /// Where the fly-off ends: past the screen's leading edge.
    static func flyOffOffset(cardMinX: CGFloat, cardWidth: CGFloat) -> CGFloat {
        // Safari's flung card ends just past the edge (its right edge at 0).
        // The card is lifted (scaled about its centre), so its drawn right
        // edge is half the lift's growth past the slot's: without it the
        // card was still 8 pt on screen when the curve ended, and the end of
        // the fling was 20 ms late.
        -(cardMinX + cardWidth * (1 + liftScale) / 2)
    }
}

/// Who owns a touch on a grid card: the swipe-to-close, or a long press
/// (its menu, or a drag to another slot).
struct CardGestures: Equatable, Sendable {
    /// The swipe may move (and close) `card` only while no long press owns it.
    static func swipeAllowed(card: String, pressed: String?, reordering: String?) -> Bool {
        pressed != card && reordering != card
    }
}

/// Close taps wait for the grid to stop moving.
struct GridTapGuard: Equatable, Sendable {
    /// About the reflow spring's settle time.
    static let settle: Double = 0.45
    static func accepts(now: Double, changedAt: Double) -> Bool { now - changedAt >= settle }
}
