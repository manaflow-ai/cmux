public import CmuxMobileSSH
public import Foundation

/// One open login shell with a PTY, over whatever connection chain reached
/// it. `events` finishes after `.closed`.
public protocol SSHShellChannel: Sendable {
    var events: AsyncStream<SSHSessionEvent> { get }
    func write(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
    /// Closes the shell and every connection opened for it.
    func close() async
}
