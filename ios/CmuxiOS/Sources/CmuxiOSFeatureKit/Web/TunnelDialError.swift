/// Why a tunnel stream could not be opened.
public enum TunnelDialError: Error, Hashable, Sendable {
    /// No session to the machine.
    case offline
    /// The machine refused (`tunnel.port_not_allowed`, `tunnel.connect_refused`, ...).
    case refused(code: String, retryable: Bool)
}
