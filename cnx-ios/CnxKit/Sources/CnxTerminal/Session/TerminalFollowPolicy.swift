import CoreGraphics

/// When the terminal's native scrollback follows the prompt (portable rules
/// of `TerminalViewController`, unit tested):
///
/// - Output while at the bottom keeps the bottom pinned; output while the
///   user scrolled up never moves them.
/// - Input (typing, the key bar, the composer, paste) on the primary screen
///   follows again and jumps to the prompt, like Terminal and Blink.
/// - When the scrollback is cleared (`clear`, ESC [3J) or the document ends
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

    /// The scrollback's total rows changed from `previous` to `total`. Only a
    /// cleared scrollback (`clear`, ESC [3J: about one screen of rows left)
    /// follows again; Ghostty trimming old pages at the scrollback limit, or a
    /// reflow, also lowers the total and must not move a reader.
    public mutating func scrollbackChanged(from previous: Int, to total: Int, screenRows: Int) {
        if total < previous, total <= max(screenRows, 1) { following = true }
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

/// When a drag with the keyboard up holds the prompt on the composer
/// (design/terminal M6, R3-1). Only once the touch has reached the keyboard,
/// so the keyboard follows the finger, and only for a drag that began at the
/// prompt: the part of the gesture that moves the keyboard ends with the
/// prompt on the composer. Above the keyboard a pull-down scrolls the history
/// like any scroll view (as in Messages).
public struct KeyboardDragPin: Equatable, Sendable {
    /// The drag began while following the prompt with the soft keyboard up.
    public private(set) var candidate = false
    /// The keyboard follows the finger: the content stays on the composer.
    public private(set) var pinning = false

    public init() {}

    public mutating func began(following: Bool, keyboardUp: Bool, isTUI: Bool) {
        candidate = following && keyboardUp && !isTUI
        pinning = false
    }

    /// The finger moved: `fingerY` and `keyboardTop` in the page's points.
    public mutating func moved(fingerY: CGFloat, keyboardTop: CGFloat) {
        guard candidate, !pinning else { return }
        if fingerY >= keyboardTop - 2 { pinning = true }
    }

    public mutating func ended() {
        candidate = false
        pinning = false
    }
}
