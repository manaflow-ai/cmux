import Foundation

/// A virtual command clock that can hold timer delivery while time advances.
/// Safety: Clock.now is synchronous; the lock protects only the test clock's instant and sleepers.
final class CloudCommandDeadlineClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var sleepers: [UUID: (Instant, AsyncStream<Void>.Continuation)] = [:]
    private let registrations = AsyncStream<Void>.makeStream()

    var now: Instant { lock.withLock { instant } }
    var minimumResolution: Duration { .nanoseconds(1) }

    func advance(by duration: Duration, wakingTimers: Bool = true) {
        let ready = lock.withLock {
            instant = instant.advanced(by: duration)
            return wakingTimers ? sleepers.values.filter { $0.0 <= instant }.map { $0.1 } : []
        }
        for continuation in ready { continuation.finish() }
    }

    func waitUntilSleeping() async {
        var iterator = registrations.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        let wakeup = AsyncStream<Void>.makeStream()
        register(id, deadline: deadline, continuation: wakeup.continuation)
        defer { remove(id) }
        registrations.continuation.yield(())
        // AsyncStream ends on cancellation, releasing even a deliberately held timer.
        for await _ in wakeup.stream {}
        try Task.checkCancellation()
    }

    private func register(_ id: UUID, deadline: Instant, continuation: AsyncStream<Void>.Continuation) {
        lock.withLock {
            if deadline <= instant { continuation.finish() }
            else { sleepers[id] = (deadline, continuation) }
        }
    }

    private func remove(_ id: UUID) {
        _ = lock.withLock { sleepers.removeValue(forKey: id) }
    }
}
