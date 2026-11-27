import Foundation

/// Clock.now is synchronous. A lock protects this test clock's instant and
/// continuation registration; no production state uses this lock.
final class CloudReadManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration
        func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
        func duration(to other: Self) -> Duration { other.offset - offset }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
    }
    private struct Waiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }
    private let lock = NSLock()
    private var instant = Instant(offset: .zero)
    private var sleepers: [UUID: Waiter] = [:]
    var now: Instant { lock.withLock { instant } }
    var minimumResolution: Duration { .zero }
    var pendingSleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else if deadline <= instant { continuation.resume() }
                    else { sleepers[id] = Waiter(deadline: deadline, continuation: continuation) }
                }
            }
        } onCancel: {
            self.lock.withLock { self.sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration, deliverTimers: Bool = true) {
        let ready: [Waiter] = lock.withLock {
            instant = instant.advanced(by: duration)
            guard deliverTimers else { return [] }
            let ready = sleepers.filter { $0.value.deadline <= instant }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return Array(ready.values)
        }
        for waiter in ready { waiter.continuation.resume() }
    }
}
