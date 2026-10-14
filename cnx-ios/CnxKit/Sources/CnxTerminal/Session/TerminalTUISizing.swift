import CoreGraphics

/// Rows the Mac's terminal gets (design/terminal R1-1). A full-screen TUI
/// (`top`, `vim`) must fit between the status bar and the composer wherever
/// the composer settled, keyboard up or down, so its header stays on screen.
///
/// - The PTY is resized once, when the keyboard has settled (did-show /
///   did-hide), never per animation frame; during the animation the
///   alternate screen stays pinned to the composer at its old size.
/// - On the primary screen the rows are those of the keyboard-down layout,
///   so showing the keyboard in a shell never redraws its prompt.
/// - The choice changes only when the keyboard settles or a TUI starts,
///   never when the alternate screen ends. A resize makes the Mac reset the
///   mirror and replay (`resized`: the alternate screen goes off, then on
///   again); following that flicker resized the PTY back and forth forever.
///   After a TUI quits with the keyboard up, the shell keeps the TUI's rows
///   until the keyboard next settles.
public struct TerminalTUISizing: Equatable, Sendable {
    /// The composer stack's top when the keyboard last settled above its
    /// resting place (nil: the keyboard is down).
    public private(set) var settledStackTop: CGFloat?
    /// Whether the rows follow `settledStackTop` (a TUI was showing when the
    /// keyboard settled, or started since).
    public private(set) var followsKeyboard = false

    public init() {}

    /// The keyboard finished showing or hiding; `stackTop` is the composer
    /// stack's top now, `restingStackTop` its top with the keyboard down.
    public mutating func keyboardSettled(stackTop: CGFloat, restingStackTop: CGFloat, isTUI: Bool) {
        settledStackTop = stackTop < restingStackTop - 0.5 ? stackTop : nil
        followsKeyboard = isTUI
    }

    /// A TUI took the alternate screen.
    public mutating func tuiStarted() {
        followsKeyboard = true
    }

    /// The rows for the PTY.
    public func rows(restingStackTop: CGFloat, chromeTop: CGFloat, cellHeight: CGFloat) -> Int {
        let bottom = (followsKeyboard ? settledStackTop : nil) ?? restingStackTop
        return max(1, Int(floor((bottom - chromeTop) / max(1, cellHeight))))
    }
}
