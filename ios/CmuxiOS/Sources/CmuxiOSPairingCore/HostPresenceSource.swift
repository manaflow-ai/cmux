/// Presence of a set of hosts, pushed by their owners (no polling).
public protocol HostPresenceSource: Sendable {
    /// Follows `hosts` (id -> team) and yields the full presence map on every change.
    func presence(of hosts: [String: String]) async -> AsyncStream<[String: HostPresence]>
}
