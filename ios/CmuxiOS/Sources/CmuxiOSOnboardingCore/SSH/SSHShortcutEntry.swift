public import CmuxiOSFeatureKit
import Foundation

/// The optional SSH host step's fields. Accepts `user@host:port` pasted into
/// the host field; blank user and port mean the SSH defaults. Keys and
/// known hosts are lane C9's; this only creates the host record.
public struct SSHShortcutEntry: Hashable, Sendable {
    public var host: String
    public var user: String
    public var port: String

    public init(host: String = "", user: String = "", port: String = "") {
        self.host = host
        self.user = user
        self.port = port
    }

    /// The host record to add, or nil when the fields are not valid.
    public var draft: HostDraft? {
        var address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        var portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = address.lastIndex(of: "@") {
            if user.isEmpty { user = String(address[..<at]) }
            address = String(address[address.index(after: at)...])
        }
        if address.hasPrefix("[") {
            // SSH users commonly paste IPv6 endpoints in URI form. Keep the
            // brackets out of HostEndpoint.address and preserve an embedded
            // port instead of handing `[addr]:port` to the SSH connector as
            // a literal hostname.
            guard let closing = address.firstIndex(of: "]") else { return nil }
            let innerStart = address.index(after: address.startIndex)
            guard closing > innerStart else { return nil }
            let inner = String(address[innerStart..<closing])
            guard !inner.contains(where: { $0 == "[" || $0 == "]" }) else { return nil }
            let suffix = String(address[address.index(after: closing)...])
            if !suffix.isEmpty {
                guard suffix.first == ":" else { return nil }
                let embeddedPort = String(suffix.dropFirst())
                guard !embeddedPort.isEmpty else { return nil }
                if portText.isEmpty { portText = embeddedPort }
            }
            address = inner
        } else if let colon = address.lastIndex(of: ":"), address.filter({ $0 == ":" }).count == 1 {
            if portText.isEmpty { portText = String(address[address.index(after: colon)...]) }
            address = String(address[..<colon])
        }
        guard !address.isEmpty, !address.contains(where: \.isWhitespace), !user.contains(where: \.isWhitespace) else { return nil }
        var portNumber: UInt16?
        if !portText.isEmpty {
            guard let value = UInt16(portText), value > 0 else { return nil }
            portNumber = value
        }
        let endpoint = HostEndpoint(address: address, port: portNumber, user: user.isEmpty ? nil : user)
        return HostDraft(name: address, kind: .ssh(endpoint: endpoint, jumpHost: nil))
    }
}
