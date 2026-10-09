import Foundation

/// One session a discovery run found, with what the list shows.
public struct SSHDiscoveredSession: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case tmux
        case screen
        case cmuxTUI = "cmux-tui"
    }

    /// One tmux window (index and name) of a session.
    public struct Window: Hashable, Sendable {
        public var index: Int
        public var name: String
        public var isActive: Bool
        public var target: SSHSessionTarget
        /// Validated read-only host geometry; nil for older or inconsistent listings.
        public var layout: SSHTmuxLayout? = nil
    }

    public var kind: Kind
    public var name: SSHSessionName
    /// Attaches to the whole session.
    public var target: SSHSessionTarget
    public var windows: [Window]
    public var isAttached: Bool
    /// Last activity (tmux `session_activity`), seconds since 1970.
    public var activity: Int64?

    /// `ssh:<kind>:<session>`, stable across runs.
    public var id: String {
        if case .tmuxControl(_, let window) = target {
            return "ssh:tmux:\(window.serverPID)-\(window.serverStart):" + window.sessionID
        }
        return "ssh:\(kind.rawValue):\(name.rawValue)"
    }
}
