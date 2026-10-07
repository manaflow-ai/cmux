import Foundation

/// Why the host store refused an intent. The raw value is the receipt's
/// `reason`, so screens map it to localized text.
public enum HostsRefusal: String, Hashable, Sendable, CaseIterable {
    /// Paired Macs are added and removed from Devices (lane B6).
    case pairedMac = "hosts.paired-mac"
    case emptyName = "hosts.empty-name"
    case emptyAddress = "hosts.empty-address"
    case unknownHost = "hosts.unknown-host"
    /// The jump host is missing or is not an SSH host.
    case unknownJumpHost = "hosts.unknown-jump-host"
    /// The jump chain would loop back to this host.
    case jumpCycle = "hosts.jump-cycle"
    /// The file could not be written; nothing changed.
    case storage = "hosts.storage"
}
