import Foundation

/// Why a Cloud call did not produce an answer from the owner.
public enum CloudAPIError: Error, Hashable, Sendable {
    /// No connection or no usable reply: the outcome is unknown.
    case transport
    /// A read the Worker or the owner refused, with its code.
    case refused(code: String)
    /// No credential for this principal (signed out, no API origin).
    case unauthenticated
}
