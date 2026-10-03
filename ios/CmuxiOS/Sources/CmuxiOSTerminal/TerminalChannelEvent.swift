public import Foundation

/// Events of one attached terminal channel (`terminal-snapshot-v1`,
/// plans/cmux-next/ghostty-next.md section 2.1).
public enum TerminalChannelEvent: Sendable {
    /// One `terminal_bytes` frame without the channel header: the terminal
    /// sub-header and its payload (`TerminalFrame`). The first frame after
    /// attach is `snapshot_ready`.
    case frame(Data)
    /// The host's canonical grid from size-state. A grid change is followed by
    /// a `snapshot_ready` frame of the same generation.
    case grid(cols: Int, rows: Int, generation: UInt32)
    /// The host throttled a `snapshot_request`; `requestID` names it when known.
    case snapshotThrottled(retryAfterMilliseconds: Int, requestID: String?)
    case path(TerminalPath, rttMilliseconds: Double?)
    case kicked(byDisplayName: String)
    case closed(reason: String)
}
