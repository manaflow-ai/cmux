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

    func close() async {
        stream.close()
        pump.cancel()
    }
}
