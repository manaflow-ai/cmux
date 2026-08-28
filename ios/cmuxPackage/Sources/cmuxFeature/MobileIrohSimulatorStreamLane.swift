import CmuxIrohTransport
import CmuxMobileRPC
import Foundation

public enum MobileIrohSimulatorStreamLaneError: Error, Equatable, Sendable {
    case closed
    case invalidPanelID
}

/// iOS owner for one independent simulator-stream v2 lane. Byte-level only:
/// the viewer package frames and decodes messages.
public actor MobileIrohSimulatorStreamLane: MobileSimulatorStreamLaneConnection {
    private let stream: CmxIrohBidirectionalStream
    private var closed = false

    init(stream: CmxIrohBidirectionalStream) {
        self.stream = stream
    }

    public func receive() async throws -> Data? {
        guard !closed else { return nil }
        return try await stream.receiveStream.receive(maximumByteCount: 256 * 1_024)
    }

    public func send(_ data: Data) async throws {
        guard !closed else { throw MobileIrohSimulatorStreamLaneError.closed }
        try await stream.sendStream.send(data)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        await stream.sendStream.reset(errorCode: 0)
        await stream.receiveStream.stop(errorCode: 0)
    }
}
