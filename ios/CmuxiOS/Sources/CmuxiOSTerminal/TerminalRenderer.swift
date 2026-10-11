public import Foundation

/// The rendering seam (lane 13, ghostty-next). Manual I/O: the renderer never
/// owns a PTY. Host output, snapshots and grid changes reach the terminal
/// only through `enqueueOutput`, in channel order; typed input leaves through
/// `onInput`.
@MainActor
public protocol TerminalRenderer: AnyObject {
    /// The GHOSTSNP version this renderer restores and encodes.
    var snapshotVersion: UInt16 { get }
    /// Runs `work` on the renderer's serial output queue (never the main
    /// thread), after all earlier work, then redraws. Returns false, and drops
    /// the work, while the renderer has no terminal.
    @discardableResult
    func enqueueOutput(_ work: @escaping @Sendable (any TerminalOutputSurface) -> Void) -> Bool
    /// The grid that fits the current view at the current font.
    var fittingGrid: (cols: Int, rows: Int) { get }
    /// Bytes to send when the user types, pastes or uses a key bar key.
    var onInput: ((Data) -> Void)? { get set }
}

/// Which part of a GHOSTSNP snapshot to restore or encode.
public enum TerminalSnapshotPhase: Sendable {
    /// Terminal state and both screens, up to the READY marker.
    case ready
    /// Scrollback pages after READY, newest first.
    case history
    /// READY followed by HISTORY.
    case complete
}

/// The terminal's grid as the renderer holds it.
public struct TerminalGrid: Hashable, Sendable {
    public var cols: Int
    public var rows: Int
    /// The generation of the last accepted grid; 0 while the grid is not locked.
    public var generation: UInt64
    public var locked: Bool

    public init(cols: Int, rows: Int, generation: UInt64, locked: Bool) {
        self.cols = cols
        self.rows = rows
        self.generation = generation
        self.locked = locked
    }
}

/// The terminal's output side. Valid only inside an `enqueueOutput` closure,
/// on the output queue; never keep it.
public protocol TerminalOutputSurface {
    /// Parses host PTY output.
    func feed(_ bytes: Data)
    /// Restores a snapshot the host encoded. READY replaces the terminal
    /// state atomically; HISTORY prepends pages. False when it was refused.
    @discardableResult
    func restore(_ snapshot: Data, phase: TerminalSnapshotPhase) -> Bool
    /// Locks the grid at the host's size. False for an older generation.
    @discardableResult
    func setGrid(cols: Int, rows: Int, generation: UInt64) -> Bool
    var grid: TerminalGrid { get }
    /// This terminal's own encoding, or nil when it cannot encode one.
    func encode(_ phase: TerminalSnapshotPhase) -> Data?
}
