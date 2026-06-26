import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TerminationWatchdogTests {
    /// The watchdog must fire its exit handler after the deadline, from a
    /// background thread that does not depend on the main run loop — the whole
    /// point is to bound a quit that has already wedged the main thread
    /// (https://github.com/manaflow-ai/cmux/issues/6758). Without a functioning
    /// `arm`, the handler never runs and this times out.
    @Test
    func armFiresExitHandlerAfterDeadline() async {
        let fired = DispatchSemaphore(value: 0)
        let watchdog = TerminationWatchdog { fired.signal() }

        watchdog.arm(deadline: 0.05)

        let result = fired.wait(timeout: .now() + 3)
        #expect(result == .success)
    }

    /// Arming is idempotent: repeated calls (multiple quit attempts, or both the
    /// primary and backstop commit sites arming for one request) must never
    /// stack threads, so the exit handler runs at most once.
    @Test
    func armIsIdempotentAndFiresExactlyOnce() async throws {
        let counter = FireCounter()
        let watchdog = TerminationWatchdog { counter.increment() }

        watchdog.arm(deadline: 0.05)
        watchdog.arm(deadline: 0.05)
        watchdog.arm(deadline: 0.05)

        // Wait well past the deadline so any stacked thread would have fired.
        try await Task.sleep(for: .milliseconds(600))
        #expect(counter.value == 1)
    }

    private final class FireCounter: Sendable {
        private let lock = NSLock()
        // SAFETY: guarded by `lock`; incremented from the watchdog thread and
        // read from the test thread.
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
