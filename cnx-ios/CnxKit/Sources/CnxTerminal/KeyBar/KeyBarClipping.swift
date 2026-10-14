import CoreGraphics

/// Which keys of the key bar's scrolling middle row are really on screen.
///
/// The middle row scrolls under the pinned esc / ctrl / alt group and the
/// joystick. A key scrolled under them is clipped from view, but its
/// accessibility frame stays where it was: activating "Left Arrow" by its
/// frame landed on ctrl. Keys not fully inside the row's visible bounds are
/// hidden from accessibility and offered as actions on the row instead.
public struct KeyBarClipping: Sendable {
    public init() {}

    /// Whether `key` (its own bounds) lies inside `visible`, the scroll
    /// view's visible bounds in the same coordinate space.
    public func isFullyVisible(_ key: CGRect, in visible: CGRect?) -> Bool {
        guard let visible else { return true }
        guard visible.width > 0, key.width > 0 else { return false }
        return key.minX >= visible.minX - 0.5 && key.maxX <= visible.maxX + 0.5
    }
}
