import Foundation

/// The exact named cmux-tui socket returned by SSH discovery.
///
/// The socket path is retained across discovery and attachment because a
/// Terminal-launched owner and an SSH login can use different runtime
/// directories. A session name alone cannot identify the discovered owner.
public struct SSHCmuxTUISocket: Hashable, Sendable {
    /// The absolute socket path on the SSH host, without shell quoting.
    public let path: String

    /// The session name derived from the socket's file name.
    public let session: SSHSessionName

    /// Validates a named socket in a `cmux-tui-<uid>` runtime directory.
    ///
    /// Directory names may contain spaces or shell punctuation; the attach
    /// command quotes the full path. Relative paths, traversal, control
    /// characters and names outside ``SSHSessionName`` are refused.
    /// - Parameter raw: The absolute socket path emitted by discovery.
    public init?(validatingPath raw: String) {
        guard raw.hasPrefix("/"), raw.hasSuffix(".sock"), raw.utf8.count <= 4096,
              !raw.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}"
              }) else { return nil }
        let components = raw.split(separator: "/")
        guard components.count >= 2, !components.contains("."), !components.contains(".."),
              let file = components.last, file.hasSuffix(".sock") else { return nil }
        let directory = components[components.count - 2]
        let prefix = "cmux-tui-"
        guard directory.hasPrefix(prefix) else { return nil }
        let uid = directory.dropFirst(prefix.count)
        guard !uid.isEmpty, uid.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let session = SSHSessionName(validating: String(file.dropLast(".sock".count))) else { return nil }
        guard session.rawValue != ".", session.rawValue != ".." else { return nil }
        path = raw
        self.session = session
    }
}
