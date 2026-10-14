import CoreGraphics

/// When the terminal's native scrollback follows the prompt (portable rules
/// of `TerminalViewController`, unit tested):
///
/// - Output while at the bottom keeps the bottom pinned; output while the
///   user scrolled up never moves them.
/// - Input (typing, the key bar, the composer, paste) on the primary screen
///   follows again and jumps to the prompt, like Terminal and Blink.
/// - When the scrollback shrinks (`clear`, ESC [3J) or the document ends
///   above the place on screen, the rows being read are gone: follow again.
public struct TerminalFollowPolicy: Sendable {
    public var following = true

    public init(following: Bool = true) {
        self.following = following
    }

    /// The user scrolled (a drag or a fling): follow only from the bottom.
    public mutating func userScrolled(offsetY: CGFloat, maxOffsetY: CGFloat, rowHeight: CGFloat) {
        following = offsetY >= maxOffsetY - rowHeight
    }

    /// The scrollback's total rows changed from `previous` to `total`.
    public mutating func scrollbackChanged(from previous: Int, to total: Int) {
        if total < previous { following = true }
    }

    /// The document's height changed; returns the offset to show, or nil to stay.
    public mutating func documentResized(offsetY: CGFloat, maxOffsetY: CGFloat, userIsScrolling: Bool) -> CGFloat? {
        if following { return userIsScrolling ? nil : maxOffsetY }
        guard !userIsScrolling, offsetY > maxOffsetY + 0.5 else { return nil }
        following = true
        return maxOffsetY
    }

    /// Input is about to go to the program; returns the offset to jump to,
    /// or nil when the prompt is already in view or a TUI owns the screen.
    public mutating func input(isTUI: Bool, offsetY: CGFloat, maxOffsetY: CGFloat) -> CGFloat? {
        guard !isTUI else { return nil }
        following = true
        return offsetY < maxOffsetY - 0.5 ? maxOffsetY : nil
    }
}
