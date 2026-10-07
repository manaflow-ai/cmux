public import CmuxiOSFeatureKit

/// The terminal whose scrollback is searched (C1's attach target).
public struct TerminalSearchTarget: Hashable, Sendable {
    public var hostID: HostID
    /// The session host's terminal (`term_...`).
    public var terminalID: String

    public init(hostID: HostID, terminalID: String) {
        self.hostID = hostID
        self.terminalID = terminalID
    }
}
