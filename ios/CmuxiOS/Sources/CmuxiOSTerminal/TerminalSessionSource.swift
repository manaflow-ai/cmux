public import CmuxTerminalStream
public import Foundation

/// The transport seam (lane 12). The phone attaches, reports its presence
/// (visible viewport for the canonical grid), and sends input as ordered,
/// attributed runtime commands that never queue offline.
public protocol TerminalSessionSource: Sendable {
    func terminals() async throws -> [TerminalRef]
    /// Each call is a new connection: viewer state from an earlier one is reset.
    func attach(_ terminal: TerminalRef) async throws -> AsyncStream<TerminalChannelEvent>
    func setPresence(_ terminal: TerminalRef, visible: Bool, cols: Int, rows: Int) async
    func send(_ input: Data, to terminal: TerminalRef) async throws
    /// Sends `snapshot_request` (`request.json`) on the terminal channel. The
    /// answer is a `snapshot_ready` frame or a `snapshotThrottled` event.
    func requestSnapshot(_ request: SnapshotRequest, for terminal: TerminalRef) async throws
    func detach(_ terminal: TerminalRef) async
}
