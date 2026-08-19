/// A connector classification that tells policy whether another route is safe to try.
public enum TransportOpenFailure: Error, Equatable, Sendable {
    /// The route is currently unavailable and another route may be attempted.
    case unavailable

    /// The peer does not speak the requested transport and another route may be attempted.
    case incompatiblePeer

    /// The route metadata is invalid and another discovered route may be attempted.
    case invalidRoute

    /// Admission failed; automatic mode must not silently bypass this denial.
    case unauthorized
}
