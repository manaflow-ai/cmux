import CmuxIrxTransport
import CmuxMobileSSH
import Foundation

/// An irx `daemon` lane as a cmux-tui line carrier: the Mac splices the
/// lane onto its daemon's Unix socket (behind an authority filter), so
/// `CmuxTUIControl` speaks protocol 12 over it exactly as over SSH.
final class IrxDaemonLaneCarrier: CmuxTUICarrier {
    let events: AsyncStream<SSHSessionEvent>
    private let lane: IrxLaneStream
    private let pump: Task<Void, Never>

    init(lane: IrxLaneStream) {
        self.lane = lane
        let (events, continuation) = AsyncStream.makeStream(of: SSHSessionEvent.self)
        self.events = events
        pump = Task {
            while !Task.isCancelled {
                guard let chunk = try? await lane.reader.readRaw(maximumByteCount: 64 * 1024) else { break }
                if !chunk.isEmpty { continuation.yield(.stdout(chunk)) }
            }
            continuation.yield(.closed)
            continuation.finish()
        }
    }

    func write(_ data: Data) async throws {
        try await lane.writer.write(data)
    }

    func close() async {
        pump.cancel()
        await lane.close()
    }
}
