public import CmuxiOSFeatureKit
import Foundation

/// The workspace terminals open on this phone, newest last, so features
/// that type into "the terminal I was in" (C4's path paste, C7's terminal
/// reply) reach the same ordered input queue the screen uses. Weak: a
/// closed screen drops its source.
@MainActor
public final class OpenLinkTerminals {
    private struct Entry {
        weak var source: DirectoryTerminalByteSource?
    }

    private var entries: [Entry] = []

    public init() {}

    func register(_ source: DirectoryTerminalByteSource) {
        entries.removeAll { $0.source == nil || $0.source === source }
        entries.append(Entry(source: source))
    }

    /// `terminal` on `host`, or the newest open terminal of `host`.
    public func source(host: HostID, terminal: String?) -> DirectoryTerminalByteSource? {
        entries.removeAll { $0.source == nil }
        return entries.reversed().compactMap(\.source).first { source in
            source.hostID == host && (terminal == nil || source.terminalID == terminal)
        }
    }
}
