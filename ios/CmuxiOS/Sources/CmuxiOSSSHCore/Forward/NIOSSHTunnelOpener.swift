public import CmuxiOSFeatureKit
public import CmuxMobileSSH
import Foundation

/// The in-app browser's SSH side (c14-web.md section 5): connects the host's
/// hop chain once (same trust and credentials as the terminal), opens one
/// `direct-tcpip` channel per proxied connection, and reconnects on the next
/// open after the connection dropped. No timer keeps it alive; the route
/// closes it when its browser goes away.
public actor NIOSSHTunnelOpener: SSHDirectTCPIPOpener {
    private let chain: SSHHostChain
    private let credentials: SSHCredentialResolver
    private let verifier: any SSHHostKeyVerifier
    private var connections: [SSHConnection] = []
    private var connecting: Task<SSHConnection, any Error>?

    public init(chain: SSHHostChain, credentials: SSHCredentialResolver, verifier: any SSHHostKeyVerifier) {
        self.chain = chain
        self.credentials = credentials
        self.verifier = verifier
    }

    public func openDirectTCPIP(host: String, port: Int) async throws -> any TunnelStream {
        let target = try await connection()
        return SSHDirectTunnelStream(stream: try await target.openDirectStream(host: host, port: port))
    }

    public func close() async {
        connecting?.cancel()
        connecting = nil
        for connection in connections.reversed() { await connection.close() }
        connections.removeAll()
    }

    private func connection() async throws -> SSHConnection {
        if let last = connections.last, last.isOpen { return last }
        if let connecting { return try await connecting.value }
        for stale in connections.reversed() { await stale.close() }
        connections.removeAll()
        let task = Task { [chain, credentials, verifier] () throws -> [SSHConnection] in
            var opened: [SSHConnection] = []
            do {
                for hop in chain.hops {
                    opened.append(try await SSHConnection.connect(to: hop.endpoint,
                                                                  credentials: try await credentials.credentials(for: hop.hostID),
                                                                  hostKeyVerifier: verifier, via: opened.last))
                }
            } catch {
                for connection in opened.reversed() { await connection.close() }
                throw SSHSessionFailure(error)
            }
            return opened
        }
        let single = Task { () throws -> SSHConnection in
            let opened = try await task.value
            self.adopt(opened)
            guard let last = opened.last else { throw SSHSessionFailure.invalidChain }
            return last
        }
        connecting = single
        defer { connecting = nil }
        return try await single.value
    }

    private func adopt(_ opened: [SSHConnection]) {
        connections = opened
    }
}
