import CmuxIrohTransport
import CmuxMobileRPC
import Foundation

/// iOS adapter that exposes only the readable half of an Iroh artifact stream.
actor MobileIrohArtifactLane: MobileArtifactLaneConnection {
    private let stream: CmxIrohBidirectionalStream
    private var closed = false

    init(stream: CmxIrohBidirectionalStream) {
        self.stream = stream
    }

    func receive(maximumByteCount: Int) async throws -> Data? {
        guard !closed else { return nil }
        return try await stream.receiveStream.receive(
            maximumByteCount: max(1, maximumByteCount)
        )
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await stream.receiveStream.stop(errorCode: 0)
        await stream.sendStream.reset(errorCode: 0)
    }
}
