import CmuxMobileSSH
import Foundation

/// A shell on `SSHSessionChannel` that owns the connections of its chain.
struct NIOSSHShellChannel: SSHShellChannel {
    let session: SSHSessionChannel
    /// Outermost first.
    let connections: [SSHConnection]

    var events: AsyncStream<SSHSessionEvent> { session.events }

    func write(_ data: Data) async throws {
        try await session.write(data)
    }

    func resize(cols: Int, rows: Int) async throws {
        try await session.resize(columns: cols, rows: rows)
    }

    func close() async {
        await session.close()
        for connection in connections.reversed() { await connection.close() }
    }
}
