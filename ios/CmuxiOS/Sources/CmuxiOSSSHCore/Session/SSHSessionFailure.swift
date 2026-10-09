import CmuxMobileSSH
import Foundation

/// Why an SSH session could not connect or ended. Carries no server text,
/// key material or credentials, so it is safe to log and show.
public enum SSHSessionFailure: Error, Hashable, Sendable {
    /// The user declined the server's identity key (or a changed key).
    case hostKeyRejected
    /// The server refused every credential offered.
    case authenticationFailed
    /// No key or password is set for a host in the chain, or it is gone.
    case missingCredentials
    /// A host in the chain has no user name.
    case missingUser
    /// The host or one of its jump hosts is not in the store, or the chain loops.
    case invalidChain
    /// The server refused the PTY or the shell.
    case shellRejected
    /// Network trouble: unreachable, timed out, or the connection dropped.
    case network
    /// The discovered session to attach to is no longer listed (E3).
    case sessionGone

    /// Whether a later attempt can succeed without the user changing anything.
    public var isRetryable: Bool { self == .network }

    /// Classifies any error a connect attempt throws.
    public init(_ error: any Error) {
        if let failure = error as? SSHSessionFailure {
            self = failure
            return
        }
        switch error as? SSHConnectionError {
        case .hostKeyRejected: self = .hostKeyRejected
        case .authenticationFailed: self = .authenticationFailed
        case .channelRequestRejected: self = .shellRejected
        case .channelOpenFailed, .closed, nil: self = .network
        case .outputLimitExceeded: self = .shellRejected
        }
    }
}
