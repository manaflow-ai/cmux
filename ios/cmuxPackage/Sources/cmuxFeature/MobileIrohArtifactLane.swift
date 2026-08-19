import CmuxMobileRPC
import CmuxPeerTransport
import Foundation

/// iOS adapter that exposes only the readable half of a peer artifact stream.
actor MobileIrohArtifactLane: MobileArtifactLaneConnection {
    private let stream: PeerByteStream
    private var closed = false

    init(stream: PeerByteStream) {
        self.stream = stream
    }

    func receive(maximumByteCount: Int) async throws -> Data? {
        guard !closed else { return nil }
        return try await stream.read(maxLength: max(1, maximumByteCount))
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await stream.reset()
    }
}
