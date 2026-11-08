import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TerminationWatchdogTests {
    /// Arming is idempotent: repeated calls (multiple quit attempts, or both the
    /// primary and backstop commit sites arming for one request) schedule the
    /// deadline exactly once, and nothing fires before the deadline elapses.
    ///
    /// Deterministic by construction — the injected scheduler captures the
    /// deadline handler instead of sleeping, so no real time is involved
    /// (https://github.com/manaflow-ai/cmux/issues/6758).
    @Test
    func repeatedArmingSchedulesTheDeadlineExactlyOnce() {
        let scheduler = CapturingScheduler()
        let counter = FireCounter()
        let watchdog = TerminationWatchdog(
            onFire: { counter.increment() },
            scheduleDeadline: scheduler.schedule
        )

        watchdog.arm(deadline: 8)
        watchdog.arm(deadline: 8)
        watchdog.arm(deadline: 8)

        #expect(scheduler.scheduledCount == 1)
        #expect(counter.value == 0)
    }

    /// When the deadline elapses, the watchdog runs its handler exactly once.
    @Test
    func elapsedDeadlineFiresTheHandlerExactlyOnce() {
        let scheduler = CapturingScheduler()
        let counter = FireCounter()
        let watchdog = TerminationWatchdog(
            onFire: { counter.increment() },
            scheduleDeadline: scheduler.schedule
        )

        watchdog.arm(deadline: 8)
        scheduler.fireAll()  // advance virtual time to the deadline

        #expect(counter.value == 1)
    }

    /// Captures scheduled deadline handlers instead of sleeping, so tests advance
    /// time by hand and stay deterministic.
    private final class CapturingScheduler: Sendable {
        private let lock = NSLock()
        // SAFETY: guarded by `lock`.
        nonisolated(unsafe) private var fires: [@Sendable () -> Void] = []

        var schedule: TerminationWatchdog.DeadlineScheduler {
            { [self] _, fire in
                lock.lock()
                fires.append(fire)
                lock.unlock()
            }
        }

        var scheduledCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return fires.count
        }

        func fireAll() {
            lock.lock()
            let snapshot = fires
            lock.unlock()
            for fire in snapshot { fire() }
        }
    }

    private final class FireCounter: Sendable {
        private let lock = NSLock()
        // SAFETY: guarded by `lock`.
        nonisolated(unsafe) private var stored = 0

        func increment() {
            lock.lock()
            stored += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
