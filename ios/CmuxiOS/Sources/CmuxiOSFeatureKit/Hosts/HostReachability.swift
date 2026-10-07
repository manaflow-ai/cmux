import Foundation

/// Whether a host answers now, and over which path.
public enum HostReachability: Hashable, Sendable {
    case unknown
    case reachable(path: String)
    case unreachable(reason: String?)
}
