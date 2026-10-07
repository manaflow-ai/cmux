public import CmuxMobileSSH
import Foundation

/// One OpenSSH `known_hosts` line: `identity algorithm base64`. The identity
/// is `host` for port 22 and `[host]:port` otherwise
/// (`SSHEndpoint.hostKeyIdentity`). Hashed (`|1|`) and marker (`@revoked`,
/// `@cert-authority`) lines are not read: the phone writes plain lines and
/// matches exact identities.
public struct SSHKnownHostsLine: Hashable, Sendable {
    public var identity: String
    public var key: SSHHostKey

    public init(identity: String, key: SSHHostKey) {
        self.identity = identity
        self.key = key
    }

    /// Parses a line; nil for blanks, comments, hashed or marker lines.
    /// A comma-separated host list yields one line per host.
    public static func parse(_ line: String) -> [SSHKnownHostsLine] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("@"), !trimmed.hasPrefix("|") else { return [] }
        let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 3, Data(base64Encoded: fields[2]) != nil, !fields[1].isEmpty else { return [] }
        let key = SSHHostKey(openSSHString: fields[1] + " " + fields[2])
        return fields[0].split(separator: ",").map { SSHKnownHostsLine(identity: $0.lowercased(), key: key) }
    }

    /// The line as written to the file.
    public var text: String { identity + " " + key.openSSHString }
}
