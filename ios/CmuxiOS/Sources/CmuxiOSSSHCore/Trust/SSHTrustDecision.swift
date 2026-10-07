import Foundation

/// The user's answer to an `SSHTrustQuestion`.
public enum SSHTrustDecision: Hashable, Sendable {
    /// Pin the presented key (replacing a changed one) and continue.
    case trust
    /// Stop the connection; nothing is pinned.
    case reject
}
