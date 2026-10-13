import CmuxMobileSSH
import CmuxWireGuard
import Foundation

/// A tunneled daemon lane as the line carrier `CmuxTUIControl` speaks over:
/// the same protocol the Mac's own frontends use, through the Mac's
/// phone allowlist.
final class TunnelCarrier: CmuxTUICarrier {
    let events: AsyncStream<SSHSessionEvent>
    private let stream: SocketStream
    private let pump: Task<Void, Never>

    init(stream: SocketStream) {
        self.stream = stream
        let (events, continuation) = AsyncStream.makeStream(of: SSHSessionEvent.self)
        self.events = events
        pump = Task {
            while let chunk = try? await stream.read(maximumBytes: 256 * 1024) {
                continuation.yield(.stdout(chunk))
            }
            continuation.yield(.closed)
            continuation.finish()
        }
    }

    func write(_ data: Data) async throws {
        try await stream.write(data)
    }

    /// Half-closes, waits (up to a second) for the Mac to end the lane too,
    /// then releases the socket: the Mac sees a clean close, not a lane left
    /// half open when the tunnel stops.
    func close() async {
        stream.shutdownWrite()
        let pump = pump
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump.value }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
        stream.close()
        pump.cancel()
    }
}
