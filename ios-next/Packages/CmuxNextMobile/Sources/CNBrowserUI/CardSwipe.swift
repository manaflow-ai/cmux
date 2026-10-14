import CoreGraphics

/// Swipe a grid card left to close it, as Safari does (measured on the
/// iPhone 17 Pro simulator, real frame timestamps; validation/browser.md
/// round 14):
///
/// - Horizontal drags only (a mostly vertical drag scrolls the grid). Left
///   follows the finger 1:1; right is rubber-banded and always springs back.
/// - No fade or scale while dragging.
/// - Release closes when the card is at least 72% of its width to the left,
///   or when the finger leaves leftward faster than 225 pt/s; otherwise the
///   card springs back (response 0.56, damping 0.92).
/// - Closing: the card flies off to the left and fades within 2-3 frames,
///   then the grid reflows with the close button's reflow spring (once the
///   host confirmed the close; a refused close brings the card back).
struct CardSwipe: Equatable, Sendable {
    static let commitFraction: CGFloat = 0.72
    static let flingVelocity: CGFloat = 225
    /// Rightward rubber band: `d * (1 - 1 / (x * c / d + 1))`.
    static let rubberDimension: CGFloat = 120
    static let rubberConstant: CGFloat = 0.55
    static let snapBack = ZoomSpring(response: 0.56, damping: 0.92)
    /// Safari's fly-off: the card is gone in 2-3 frames, then the reflow.
    static let flyOffDuration = 0.04
    /// Reduce Motion: no movement after release, a crossfade instead.
    static let reduceMotionFade = 0.18

    /// The card's offset for a finger translation.
    static func offset(translation dx: CGFloat) -> CGFloat {
        guard dx > 0 else { return dx }
        let d = rubberDimension
        return d * (1 - 1 / (dx * rubberConstant / d + 1))
    }

    /// Close on release? `offset` and `velocity` in points (/s), negative left.
    static func commits(offset: CGFloat, velocity: CGFloat, cardWidth: CGFloat) -> Bool {
        guard offset < 0, velocity < flingVelocity else { return false }
        return offset <= -commitFraction * cardWidth || velocity <= -flingVelocity
    }

    /// Where the fly-off ends: past the screen's leading edge.
    static func flyOffOffset(cardMinX: CGFloat, cardWidth: CGFloat) -> CGFloat {
        -(cardMinX + cardWidth + 24)
    }
}
