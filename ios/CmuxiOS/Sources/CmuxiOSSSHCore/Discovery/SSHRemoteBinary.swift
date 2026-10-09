import CmuxMobileSSH
import Foundation

/// A program on the SSH host: an absolute path discovery found (plain
/// characters only), or a bare name the remote `PATH` resolves.
public struct SSHRemoteBinary: Hashable, Sendable {
    public let path: String

    /// An absolute path of `[A-Za-z0-9_./+-]`, no `..` component; nil otherwise.
    public init?(validatingPath raw: String) {
        let bytes = raw.utf8
        guard bytes.first == UInt8(ascii: "/"), (2...512).contains(bytes.count),
              bytes.allSatisfy({ SSHSessionName.isAllowed($0) && $0 != UInt8(ascii: ":") || $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "+") }),
              !raw.split(separator: "/").contains("..") else { return nil }
        path = raw
    }

    private init(name: String) { path = name }

    public static let tmux = SSHRemoteBinary(name: "tmux")
    public static let screen = SSHRemoteBinary(name: "screen")
    public static let cmuxTUI = SSHRemoteBinary(name: "cmux-tui")

    /// The path quoted for the remote shell.
    var quoted: String { path.posixShellSingleQuoted }
}
