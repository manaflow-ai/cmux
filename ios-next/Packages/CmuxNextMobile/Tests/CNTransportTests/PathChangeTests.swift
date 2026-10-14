import CNTransport
import Foundation
import Testing

/// A transport whose events the test drives.
final class ScriptedTransport: LinkTransport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    let continuation: AsyncStream<TransportEvent>.Continuation
    init() { (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self) }
    func send(_ chunks: [Data], on lane: Lane) throws {}
    func close() { continuation.yield(.closed(reason: nil)); continuation.finish() }
    func pathInfo() async -> PathInfo { PathInfo(transport: "scripted") }
}

@Suite struct PathChangeTests {
    @Test func hostClientForwardsTransportPathChanges() async throws {
        let transport = ScriptedTransport()
        let client = HostClient(transport: transport)
        let changes = client.pathChanges()
        let relay = PathInfo(transport: "webrtc", localCandidate: .relay, remoteCandidate: .prflx)
        transport.continuation.yield(.pathChanged(relay))
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() == relay)
        client.close()
        #expect(await iterator.next() == nil) // finishes with the link
    }
}
