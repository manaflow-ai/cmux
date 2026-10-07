import Foundation

/// The owner side of a mock seam: one value, a revision, and every
/// subscriber's stream. Each mutation bumps the revision and yields one
/// snapshot to every subscriber; slow subscribers keep only the newest
/// snapshot (the same coalescing the real mirrors use). Feature lanes reuse
/// it for their own mocks.
public actor MockSnapshotHub<Value: Sendable> {
    private var revision: UInt64 = 1
    private var value: Value
    private var connection: SourceConnection
    private var subscribers: [UUID: AsyncStream<SourceSnapshot<Value>>.Continuation] = [:]

    public init(_ value: Value, connection: SourceConnection = .live(path: "mock")) {
        self.value = value
        self.connection = connection
    }

    public var current: SourceSnapshot<Value> {
        SourceSnapshot(revision: revision, value: value, connection: connection)
    }

    /// A stream that yields the current snapshot first.
    public func stream() -> AsyncStream<SourceSnapshot<Value>> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SourceSnapshot<Value>.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        continuation.yield(current)
        return stream
    }

    /// Applies a change as the owner would commit it, on a copy: a thrown
    /// error (usually `MockRefusal`) leaves value and revision unchanged.
    /// Throws `.offline` while the mock is disconnected (nothing queues).
    @discardableResult
    public func commit<Result: Sendable>(
        _ change: @Sendable (inout Value) throws -> Result
    ) throws -> (revision: UInt64, result: Result) {
        guard connection.isLive else { throw FeatureSourceError.offline }
        var next = value
        let result = try change(&next)
        value = next
        revision += 1
        broadcast()
        return (revision, result)
    }

    /// `commit` as an intent: a `MockRefusal` becomes a `.refused` receipt.
    public func receipt(for key: IntentKey, _ change: @Sendable (inout Value) throws -> Void) throws -> IntentReceipt {
        do {
            return .committed(key: key, revision: try commit(change).revision)
        } catch let refusal as MockRefusal {
            return .refused(key: key, reason: refusal.reason)
        }
    }

    /// DEV previews: drop or restore the mock owner's connection.
    public func setConnection(_ connection: SourceConnection) {
        guard connection != self.connection else { return }
        self.connection = connection
        broadcast()
    }

    public var subscriberCount: Int { subscribers.count }

    private func broadcast() {
        let snapshot = current
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }
}
