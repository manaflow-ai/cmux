/// How a terminal's bytes reach the phone (transport plan, lane 12): shown as
/// a badge, and interactive surfaces never present a relayed path as direct.
public enum TerminalPath: String, Hashable, Sendable {
    /// Same network as the host.
    case lan
    /// A NAT-punched direct WireGuard path.
    case direct
    /// Through the cloud tunnel into the team network ("via cloud region").
    case viaCloudRegion
    /// The per-host relay fallback.
    case relayed
}
