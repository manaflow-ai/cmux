public import CmuxMobileSSH
import Foundation

/// The real connector: the chain through `SSHChainDialer`, then a PTY and a
/// login shell (or, with `command`, that command) on the last hop.
public struct NIOSSHShellConnector: SSHShellConnector {
    private let dialer: SSHChainDialer
    private let term: String
    private let command: String?

    public init(chain: SSHHostChain, credentials: SSHCredentialResolver, verifier: any SSHHostKeyVerifier,
                keepalive: SSHKeepalive = SSHKeepalive(), term: String = "xterm-256color") {
        dialer = SSHChainDialer(chain: chain, credentials: credentials, verifier: verifier, keepalive: keepalive)
        self.term = term
        command = nil
    }

    /// Attaches to a discovered session instead of starting a login shell.
    public init(dialer: SSHChainDialer, attaching target: SSHSessionTarget, term: String = "xterm-256color") {
        self.dialer = dialer
        self.term = term
        command = target.attachCommand
    }

    public func openShell(cols: Int, rows: Int) async throws -> any SSHShellChannel {
        let opened = try await dialer.dial()
        do {
            guard let target = opened.last else { throw SSHSessionFailure.invalidChain }
            let start: SSHSessionStart = command.map(SSHSessionStart.exec) ?? .shell
            let session = try await target.openSession(pty: SSHPTYRequest(term: term, columns: cols, rows: rows), start: start)
            return NIOSSHShellChannel(session: session, connections: opened)
        } catch {
            for connection in opened.reversed() { await connection.close() }
            throw SSHSessionFailure(error)
        }
    }
}
