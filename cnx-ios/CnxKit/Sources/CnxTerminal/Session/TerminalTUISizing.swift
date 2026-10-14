import CoreGraphics

/// Rows the Mac's terminal gets (design/terminal R1-1). A full-screen TUI
/// (`top`, `vim`) must fit between the status bar and the composer wherever
/// the composer settled, keyboard up or down, so its header stays on screen.
/// The PTY is resized once, when the keyboard has settled (did-show /
/// did-hide), never per animation frame; during the animation the alternate
/// screen stays pinned to the composer at its old size. On the primary screen
/// the rows stay those of the keyboard-down layout, so showing the keyboard
/// in a shell never redraws its prompt.
public struct TerminalTUISizing: Equatable, Sendable {
    /// The composer stack's top when the keyboard last settled (nil: never, or
    /// the keyboard is down).
    public private(set) var settledStackTop: CGFloat?

    public init() {}

    /// The keyboard finished showing or hiding; `stackTop` is the composer
    /// stack's top now, `restingStackTop` its top with the keyboard down.
    public mutating func keyboardSettled(stackTop: CGFloat, restingStackTop: CGFloat) {
        settledStackTop = stackTop < restingStackTop - 0.5 ? stackTop : nil
    }

    /// The rows for the PTY.
    public func rows(isTUI: Bool, restingStackTop: CGFloat, chromeTop: CGFloat, cellHeight: CGFloat) -> Int {
        let bottom = (isTUI ? settledStackTop : nil) ?? restingStackTop
        return max(1, Int(floor((bottom - chromeTop) / max(1, cellHeight))))
    }
}
