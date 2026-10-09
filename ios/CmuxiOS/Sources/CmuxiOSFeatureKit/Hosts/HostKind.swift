import Foundation

/// How the phone reaches a host.
public enum HostKind: Hashable, Sendable {
    /// A Mac paired with this account (lane B6); reached through `CmuxLink`.
    case pairedMac
    /// An SSH host (lane C9). `jumpHost` names another host record.
    case ssh(endpoint: HostEndpoint, jumpHost: HostID?)
    /// A user-entered address dialed directly (lane B4): Tailscale, WireGuard or LAN,
    /// pinned to the host's key.
    case direct(endpoint: HostEndpoint, hostKey: DirectHostKey)
}
