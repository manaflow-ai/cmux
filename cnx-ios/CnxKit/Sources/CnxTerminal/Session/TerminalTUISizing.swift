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
/// - When the TUI quits, the shell gets its keyboard-down rows back at once
///   (R2-1): with the TUI's rows kept, the shell's earlier output sat above
///   the screen, unreachable, over a band of black. A resize's mirror reset
///   no longer reports the alternate screen off and on again
///   (`DaemonTerminalInbound.resetMirror(alternate:)`), so this cannot
///   resize the PTY back and forth.
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

    /// The TUI left the alternate screen.
    public mutating func tuiEnded() {
        followsKeyboard = false
    }

    /// The rows for the PTY.
    public func rows(restingStackTop: CGFloat, chromeTop: CGFloat, cellHeight: CGFloat) -> Int {
        let bottom = (followsKeyboard ? settledStackTop : nil) ?? restingStackTop
        return max(1, Int(floor((bottom - chromeTop) / max(1, cellHeight))))
    }
}

/// When a new grid size reaches the Mac (user report 2026-10-14, "blinking
/// and oscillating"). Every resize makes the Mac reset the phone's mirror and
/// replay the whole history, and an inline TUI such as Codex redraw its whole
/// transcript. Layout passes measured the page mid-change (the toolbar or
/// keyboard insets in flux) and sent 53x39 then 53x42 40 ms apart: two resets
/// and two full redraws for nothing. A size goes to the Mac only once it has
/// held for `settle`; one that reverts before then is dropped. The first size
/// goes at once (the attach needs it).
public struct TerminalResizeSettle: Equatable, Sendable {
    public struct Size: Equatable, Sendable {
        public var columns: Int
        public var rows: Int
        public init(columns: Int, rows: Int) { self.columns = columns; self.rows = rows }
    }

    public static let settle: Duration = .milliseconds(250)

    /// The size the Mac was last given.
    public private(set) var applied: Size?
    /// A size measured but not yet sent.
    public private(set) var pending: Size?

    public init() {}

    public enum Action: Equatable, Sendable {
        /// Send now (the first size).
        case sendNow(Size)
        /// Wait `settle`, then ask `settled()`.
        case wait
        case nothing
    }

    /// The layout measured `size`.
    public mutating func measured(_ size: Size) -> Action {
        guard let applied else {
            self.applied = size
            pending = nil
            return .sendNow(size)
        }
        if size == applied {
            pending = nil
            return .nothing
        }
        if pending == size { return .nothing }
        pending = size
        return .wait
    }

    /// `settle` passed since the last change: the size to send, if any.
    public mutating func settled() -> Size? {
        guard let size = pending else { return nil }
        pending = nil
        applied = size
        return size
    }
}
