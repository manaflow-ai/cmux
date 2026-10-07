public import CmuxMobileSSH
import Foundation

/// The real connector: `SSHConnection` hop by hop (each later hop rides a
/// `direct-tcpip` channel of the previous one), kernel TCP keepalive on the
/// outer transport, then a PTY and a login shell on the last hop.
public struct NIOSSHShellConnector: SSHShellConnector {
    private let chain: SSHHostChain
    private let credentials: SSHCredentialResolver
    private let verifier: any SSHHostKeyVerifier
    private let keepalive: SSHKeepalive
    private let term: String

    public init(chain: SSHHostChain, credentials: SSHCredentialResolver, verifier: any SSHHostKeyVerifier,
                keepalive: SSHKeepalive = SSHKeepalive(), term: String = "xterm-256color") {
        self.chain = chain
        self.credentials = credentials
        self.verifier = verifier
        self.keepalive = keepalive
        self.term = term
    }

    public func openShell(cols: Int, rows: Int) async throws -> any SSHShellChannel {
        var opened: [SSHConnection] = []
        do {
            for hop in chain.hops {
                let connection = try await SSHConnection.connect(
                    to: hop.endpoint,
                    credentials: try await credentials.credentials(for: hop.hostID),
                    hostKeyVerifier: verifier,
                    via: opened.last,
                    keepalive: opened.isEmpty ? keepalive : nil
                )
                opened.append(connection)
            }
            guard let target = opened.last else { throw SSHSessionFailure.invalidChain }
            let session = try await target.openSession(pty: SSHPTYRequest(term: term, columns: cols, rows: rows), start: .shell)
            return NIOSSHShellChannel(session: session, connections: opened)
        } catch {
            for connection in opened.reversed() { await connection.close() }
            throw SSHSessionFailure(error)
        }
    }
}
