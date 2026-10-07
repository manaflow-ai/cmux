public import CmuxiOSSSHCore
public import CmuxMobileSSH
import Foundation

/// The real opener: the host's hop chain with the same trust prompts and
/// credentials as its terminal (C9), then the `sftp` subsystem on the last
/// hop. One connection per host; concurrent callers share one connect.
public actor NIOSSHSFTPOpener: SFTPSessionOpening {
    private let chain: SSHHostChain
    private let credentials: SSHCredentialResolver
    private let verifier: any SSHHostKeyVerifier
    private var connections: [SSHConnection] = []
    private var client: SFTPClient?
    private var connecting: Task<SFTPClient, any Error>?

    public init(chain: SSHHostChain, credentials: SSHCredentialResolver, verifier: any SSHHostKeyVerifier) {
        self.chain = chain
        self.credentials = credentials
        self.verifier = verifier
    }

    public func fileSystem() async throws -> any SFTPFileSystem {
        if let client, connections.last?.isOpen == true { return client }
        if let connecting { return try await connecting.value }
        await reset()
        let task = Task { [chain, credentials, verifier] () throws -> ([SSHConnection], SFTPClient) in
            var opened: [SSHConnection] = []
            do {
                for hop in chain.hops {
                    opened.append(try await SSHConnection.connect(
                        to: hop.endpoint, credentials: try await credentials.credentials(for: hop.hostID),
                        hostKeyVerifier: verifier, via: opened.last))
                }
                guard let last = opened.last else { throw SSHSessionFailure.invalidChain }
                return (opened, try await SFTPClient.open(on: last))
            } catch {
                for connection in opened.reversed() { await connection.close() }
                throw error is SFTPError ? error : SSHSessionFailure(error)
            }
        }
        let single = Task { () throws -> SFTPClient in
            let (opened, client) = try await task.value
            self.adopt(opened, client)
            return client
        }
        connecting = single
        defer { connecting = nil }
        return try await single.value
    }

    public func reset() async {
        let client = client
        let connections = connections
        self.client = nil
        self.connections = []
        await client?.close()
        for connection in connections.reversed() { await connection.close() }
    }

    public func close() async {
        connecting?.cancel()
        connecting = nil
        await reset()
    }

    private func adopt(_ opened: [SSHConnection], _ client: SFTPClient) {
        connections = opened
        self.client = client
    }
}
