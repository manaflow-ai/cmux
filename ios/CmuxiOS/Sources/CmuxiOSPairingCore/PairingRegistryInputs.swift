import CmuxiOSFeatureKit
import CmuxPairing

/// The registry's latest inputs (mirror, connection, presence), coalesced
/// into one stream of changes. Owned by one registry `follow` task.
actor PairingRegistryInputs {
    struct Snapshot: Sendable {
        var state: TrustStoreState
        var presence: [String: HostPresence]
        var connection: SourceConnection
    }

    private var state: TrustStoreState?
    private var presence: [String: HostPresence] = [:]
    private var connection: SourceConnection = .connecting
    private var changeSinks: [AsyncStream<Snapshot>.Continuation] = []
    private var stateSinks: [AsyncStream<TrustStoreState>.Continuation] = []

    func set(state next: TrustStoreState) {
        state = next
        for sink in stateSinks { sink.yield(next) }
        publish()
    }

    func set(presence next: [String: HostPresence]) {
        presence = next
        publish()
    }

    func set(connection next: SourceConnection) {
        connection = next
        publish()
    }

    func changes() -> AsyncStream<Snapshot> {
        let (stream, sink) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
        changeSinks.append(sink)
        if let state { sink.yield(Snapshot(state: state, presence: presence, connection: connection)) }
        return stream
    }

    func states() -> AsyncStream<TrustStoreState> {
        let (stream, sink) = AsyncStream.makeStream(of: TrustStoreState.self, bufferingPolicy: .bufferingNewest(1))
        stateSinks.append(sink)
        if let state { sink.yield(state) }
        return stream
    }

    private func publish() {
        // Until the first snapshot the list is unknown; the registry already showed `.connecting`.
        guard let state else { return }
        let snapshot = Snapshot(state: state, presence: presence, connection: connection)
        for sink in changeSinks { sink.yield(snapshot) }
    }
}
