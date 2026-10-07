import Foundation

/// How a seam reaches its owner right now. Screens show the offline state
/// and refuse changes while not `.live` (nothing queues).
public enum SourceConnection: Hashable, Sendable {
    case connecting
    /// `path` is a short badge for the carrier in use (for example "direct",
    /// "p2p", "relay"); nil when the source does not know.
    case live(path: String?)
    case offline(reason: String?)

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}
