import CoreGraphics

/// Which keys of the key bar's scrolling middle row are really on screen.
///
/// The middle row scrolls under the pinned esc / ctrl / alt group and the
/// joystick. A key scrolled under them is clipped from view, but its
/// accessibility frame stays where it was: activating "Left Arrow" by its
/// frame landed on ctrl. An activation lands on the frame's center, so a key
/// whose center is outside the row's visible bounds is hidden from
/// accessibility and offered as an action on the row instead. A key cut at
/// an edge but with its center showing stays (tapping its center hits it).
public struct KeyBarClipping: Sendable {
    public init() {}

    /// Whether `key`'s activation point (its center) is inside `visible`,
    /// the scroll view's visible bounds in the same coordinate space.
    public func isActivatable(_ key: CGRect, in visible: CGRect?) -> Bool {
        guard let visible else { return true }
        guard visible.width > 0, key.width > 0 else { return false }
        return key.midX > visible.minX && key.midX < visible.maxX
    }
}
