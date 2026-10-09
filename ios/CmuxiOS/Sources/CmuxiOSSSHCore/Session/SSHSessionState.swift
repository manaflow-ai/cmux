import Foundation

/// Where an SSH terminal's connection is; the screen's banner shows it.
public enum SSHSessionState: Hashable, Sendable {
    case idle
    case connecting
    case live
    /// The connection dropped; attempt `attempt` starts after `delay`.
    case reconnecting(attempt: Int, delay: Duration)
    /// The remote shell exited (status when the server reported one).
    case exited(status: Int?)
    /// Stopped for a reason a retry cannot fix, or retries ran out.
    case failed(SSHSessionFailure)
    /// The viewer closed the session.
    case closed
}
