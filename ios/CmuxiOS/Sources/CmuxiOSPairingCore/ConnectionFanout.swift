import CmuxControlPlane
import CmuxiOSFeatureKit

/// `ControlPlaneClient.states` may be iterated once; this reads it for the
/// client's lifetime and hands every subscriber the latest connection and
/// each change after it.
actor ConnectionFanout {
    private let client: ControlPlaneClient
    private var latest: SourceConnection?
    private var sinks: [ObjectIdentifier: AsyncStream<SourceConnection>.Continuation] = [:]
    private var reader: Task<Void, Never>?

    init(client: ControlPlaneClient) { self.client = client }

    func stream() async -> AsyncStream<SourceConnection> {
        if reader == nil {
            latest = ControlPlanePairingOps.connection(await client.state)
            let states = client.states
            reader = Task {
                for await state in states { self.publish(ControlPlanePairingOps.connection(state)) }
            }
        }
        let (stream, sink) = AsyncStream.makeStream(of: SourceConnection.self, bufferingPolicy: .bufferingNewest(1))
        let box = SinkBox()
        sinks[ObjectIdentifier(box)] = sink
        if let latest { sink.yield(latest) }
        sink.onTermination = { _ in Task { await self.drop(box) } }
        return stream
    }

    private func publish(_ connection: SourceConnection) {
        latest = connection
        for sink in sinks.values { sink.yield(connection) }
    }

    private func drop(_ box: SinkBox) { sinks[ObjectIdentifier(box)] = nil }
}

/// Identity of one subscriber.
final class SinkBox: Sendable {}
