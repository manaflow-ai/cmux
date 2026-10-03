import Foundation

/// One attached terminal as a renderer sees it, whatever carries it: a Mac terminal over the
/// WebRTC `daemon` channel (cmux-tui `attach-surface` bytes), a cmux-tui or tmux pane over SSH, or a
/// plain SSH shell. The renderer feeds every byte to its local emulator in order.
public enum TerminalAttachmentEvent: Sendable, Equatable {
    /// Full state to replace the screen with (VT bytes that redraw it), and the grid it was taken at.
    case snapshot(Data, columns: Int, rows: Int)
    /// Live PTY output, in order after the snapshot.
    case output(Data)
    /// The shared grid changed size (another viewer, the Mac window, or our own request).
    case resized(columns: Int, rows: Int)
    /// The terminal's colors changed (OSC palette, theme): `palette` maps index to "#rrggbb",
    /// `foreground`/`background`/`cursor` are "#rrggbb" when known.
    case colors(palette: [Int: String], foreground: String?, background: String?, cursor: String?)
    case title(String)
    /// The attachment ended; `reattachable` is false when the terminal itself is gone.
    case ended(reason: String, reattachable: Bool)
}

/// What a terminal view drives. Implementations are owned by RTCAppCore (Mac) and RTCAppSSH.
public protocol TerminalAttachment: AnyObject, Sendable {
    /// Stable id of the terminal (cmux-tui surface id, tmux pane id, or an SSH session id).
    var terminalID: String { get }
    /// Events in order; finishes after `.ended`.
    var events: AsyncStream<TerminalAttachmentEvent> { get }
    /// Raw input bytes exactly as typed (already VT-encoded by the caller).
    func send(_ bytes: Data) async throws
    /// Pasted text: bracketed when the program asked for it; `submit` adds one Return after it.
    func paste(_ text: String, submit: Bool) async throws
    /// The grid this viewer wants (its visible size); `countsTowardSize` false = viewer only.
    func resize(columns: Int, rows: Int, countsTowardSize: Bool) async throws
    /// Mouse wheel / scroll in programs that read the mouse (alt screen), in rows.
    func scroll(rows: Int, column: Int, row: Int) async throws
    /// A click at a cell (for mouse-mode TUIs).
    func click(column: Int, row: Int) async throws
    /// Detaches this view; the terminal keeps running on its host.
    func detach() async
}
