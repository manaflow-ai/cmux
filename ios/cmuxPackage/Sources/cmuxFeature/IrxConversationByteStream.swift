import CmuxConversation
import CmuxIrxTransport
import Foundation

/// An irx lane as a ``ConversationByteStream``: the agent GUI's acpmux
/// control lane or one attachment transfer, spliced on the Mac to acpmux.
actor IrxConversationByteStream: ConversationByteStream {
    private let lane: IrxLaneStream
    private var closed = false

    init(lane: IrxLaneStream) {
        self.lane = lane
    }

    func read(maximumBytes: Int) async throws -> Data? {
        if closed { return nil }
        return try await lane.reader.readRaw(maximumByteCount: maximumBytes)
    }

    func write(_ data: Data) async throws {
        try await lane.writer.write(data)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await lane.close()
    }
}
