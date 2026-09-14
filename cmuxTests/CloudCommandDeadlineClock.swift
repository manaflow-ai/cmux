import Foundation
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#elseif canImport(CloudCommandFixture)
@testable import CloudCommandFixture
#endif

/// A resume-order fixture: time advances while the timer task stays suspended.
/// Safety: Clock.now is synchronous, so its tiny test-only instant is lock protected.
final class CloudCommandDeadlineClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    let timerRegistered = CloudLinkFirstValue<Bool>()

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }
    var minimumResolution: Duration { .nanoseconds(1) }

    func advanceWithoutWakingTimer(by duration: Duration) {
        lock.lock()
        instant = instant.advanced(by: duration)
        lock.unlock()
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        timerRegistered.resolve(true)
        // Deliberately withhold the timer's wakeup; cancellation still releases it.
        _ = await CloudLinkFirstValue<Bool>().result
        try Task.checkCancellation()
    }
}
