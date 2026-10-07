public import Foundation

/// A Mac's presence from its `host:<host>` stream (b1-control-do.md 4).
public struct HostPresence: Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case online, offline, sleeping, paused
    }

    public var state: State
    /// When the owner last changed it.
    public var at: Date

    public init(state: State, at: Date) {
        self.state = state
        self.at = at
    }
}
