import Foundation

/// Runs one non-interactive command on an SSH host, with `input` on its
/// stdin, and returns its stdout. Throws `SSHSessionFailure` when the host
/// cannot be reached or refuses.
public protocol SSHCommandRunning: Sendable {
    func run(_ command: String, input: String?) async throws -> String
}
