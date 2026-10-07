import Foundation

/// Runs one non-interactive command on an SSH host and returns its stdout.
/// Throws `SSHSessionFailure` when the host cannot be reached or refuses.
public protocol SSHCommandRunning: Sendable {
    func run(_ command: String) async throws -> String
}
