public import Foundation

/// A terminal the user can open from the phone: owned by the session host on
/// one machine (Mac, mini, Cloud VM, server).
public struct TerminalRef: Hashable, Sendable, Identifiable {
    public var host: String
    public var terminal: String
    public var title: String
    public var hostName: String

    public init(host: String, terminal: String, title: String, hostName: String) {
        self.host = host
        self.terminal = terminal
        self.title = title
        self.hostName = hostName
    }

    public var id: String { host + "/" + terminal }
}
