import CmuxMobileSSH
import Foundation

/// `SSHCommandRunning` over a fresh chain per run (no PTY); the connections
/// close when the command ends.
public struct NIOSSHCommandRunner: SSHCommandRunning {
    private let dialer: SSHChainDialer

    public init(dialer: SSHChainDialer) { self.dialer = dialer }

    public func run(_ command: String, input: String?) async throws -> String {
        let opened = try await dialer.dial()
        let outcome: Result<String, SSHSessionFailure>
        if let target = opened.last {
            do {
                outcome = .success(try await target.exec(command, stdin: input.map { Data($0.utf8) }).stdoutString)
            } catch {
                outcome = .failure(SSHSessionFailure(error))
            }
        } else {
            outcome = .failure(.invalidChain)
        }
        for connection in opened.reversed() { await connection.close() }
        return try outcome.get()
    }
}
