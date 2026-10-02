public import Foundation

/// The rendering seam (lane 13, ghostty-next). Manual I/O: the renderer never
/// owns a PTY; the app feeds it bytes from the channel and forwards its
/// encoded input to the source.
@MainActor
public protocol TerminalRenderer: AnyObject {
    func feed(_ bytes: Data)
    func reset(snapshot: Data, cols: Int, rows: Int)
    /// The grid that fits the current view at the current font.
    var fittingGrid: (cols: Int, rows: Int) { get }
    /// Bytes to send when the user types, pastes or uses a key bar key.
    var onInput: ((Data) -> Void)? { get set }
}
