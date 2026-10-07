import Foundation

/// One concrete `Host` block of a pasted `~/.ssh/config`, after `Host *`
/// defaults were applied. Only the fields a phone host uses are kept.
public struct SSHConfigEntry: Hashable, Sendable {
    /// The `Host` alias the user types (`ssh devbox`).
    public var alias: String
    /// `HostName`, or the alias when absent.
    public var hostName: String
    public var port: UInt16?
    public var user: String?
    /// The first `ProxyJump` hop as written (`bastion`, `me@jump:2222`);
    /// nil for none or `none`.
    public var proxyJump: String?

    public init(alias: String, hostName: String, port: UInt16? = nil, user: String? = nil, proxyJump: String? = nil) {
        self.alias = alias
        self.hostName = hostName
        self.port = port
        self.user = user
        self.proxyJump = proxyJump
    }
}
