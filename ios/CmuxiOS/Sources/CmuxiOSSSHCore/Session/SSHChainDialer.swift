public import CmuxMobileSSH
import Foundation

/// Connects a host chain hop by hop (each later hop rides a `direct-tcpip`
/// channel of the previous one), with kernel TCP keepalive on the outer
/// transport. Shared by the shell, attach and command paths.
public struct SSHChainDialer: Sendable {
    private let chain: SSHHostChain
    private let credentials: SSHCredentialResolver
    private let verifier: any SSHHostKeyVerifier
    private let keepalive: SSHKeepalive

    public init(chain: SSHHostChain, credentials: SSHCredentialResolver, verifier: any SSHHostKeyVerifier,
                keepalive: SSHKeepalive = SSHKeepalive()) {
        self.chain = chain
        self.credentials = credentials
        self.verifier = verifier
        self.keepalive = keepalive
    }

    /// The open connections, outermost first; the last reaches the host.
    /// On failure every opened hop is closed and the error is classified.
    public func dial() async throws -> [SSHConnection] {
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
            guard !opened.isEmpty else { throw SSHSessionFailure.invalidChain }
            return opened
        } catch {
            for connection in opened.reversed() { await connection.close() }
            throw SSHSessionFailure(error)
        }
    }
}
