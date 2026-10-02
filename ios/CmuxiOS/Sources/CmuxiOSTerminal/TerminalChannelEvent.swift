public import Foundation

/// Events of one attached terminal channel (`terminal_bytes`: snapshot, then live bytes).
public enum TerminalChannelEvent: Sendable {
    case snapshot(Data, cols: Int, rows: Int)
    case bytes(Data)
    case resized(cols: Int, rows: Int)
    case path(TerminalPath, rttMilliseconds: Double?)
    case kicked(byDisplayName: String)
    case closed(reason: String)
}
