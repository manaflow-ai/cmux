import Foundation

/// Why a channel could not take an op.
public enum WorkspaceChannelError: Error, Hashable, Sendable {
    /// No live socket; nothing was sent.
    case notConnected
    /// The socket closed with the op in flight; the outcome is unknown.
    case outcomeUnknown
}
