public import CmuxiOSFeatureKit

/// One terminal's draft slot: the Mac (host id) and the session host's
/// terminal (`term_…`). Terminal ids are only unique per Mac.
public struct TerminalDraftKey: Hashable, Sendable {
    public var host: HostID
    public var terminal: String

    public init(host: HostID, terminal: String) {
        self.host = host
        self.terminal = terminal
    }

    /// The key in the stored file.
    var storageKey: String { host.rawValue + "\u{1F}" + terminal }
}
