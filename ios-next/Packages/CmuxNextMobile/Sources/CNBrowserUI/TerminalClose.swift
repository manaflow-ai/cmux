import CNCore
import Foundation

/// Closing a terminal's card on the grid.
struct TerminalClose: Equatable, Sendable {
    /// The host's close failed because the terminal is already gone: it
    /// ended on the Mac (cmux15 answers "terminal s7 ended on the Mac") or
    /// the host does not know it (`not_found`). The card's removal stands:
    /// the close succeeds locally (re-audit 2: the card came back with an
    /// error banner and could not be closed).
    static func isGone(_ error: Error) -> Bool {
        guard let rpc = error as? RPCError else { return false }
        if rpc.code == .notFound { return true }
        return rpc.message.range(of: "ended", options: .caseInsensitive) != nil
    }
}
