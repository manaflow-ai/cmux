import Foundation

/// Opens a login shell for one host: connects (jump hosts first), verifies
/// host keys, authenticates and requests a PTY of `cols` x `rows`. Throws
/// `SSHSessionFailure` (or an error it classifies).
public protocol SSHShellConnector: Sendable {
    func openShell(cols: Int, rows: Int) async throws -> any SSHShellChannel
}
