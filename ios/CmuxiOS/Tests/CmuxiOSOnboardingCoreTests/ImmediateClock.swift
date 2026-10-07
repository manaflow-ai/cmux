import Foundation

/// A test clock whose sleeps return at once and are recorded.
final class ImmediateClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var _now = Instant(offset: .zero)
    private var _sleeps: [Duration] = []

    var now: Instant { lock.withLock { _now } }
    var minimumResolution: Duration { .zero }
    var sleeps: [Duration] { lock.withLock { _sleeps } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        lock.withLock {
            _sleeps.append(_now.duration(to: deadline))
            _now = deadline
        }
    }
}
