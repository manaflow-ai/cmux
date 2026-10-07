import Foundation

/// What `ShellRouter` did with a link.
public enum ShellRouteOutcome: Hashable, Sendable {
    /// Delivered to the shell now.
    case handled
    /// Parked until an account is ready; delivered once then.
    case deferred
    /// Not a cmux link this build understands.
    case unrecognized
}
