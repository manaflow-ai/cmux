import Foundation
import Testing
@testable import cmux_DEV

/// Deterministic clock: sleeps suspend until the test advances time.
final class SidebarTestManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var _now = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return _now
    }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let readyNow: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return deadline <= _now
        }()
        if readyNow { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if deadline <= _now {
                lock.unlock()
                continuation.resume()
                return
            }
            sleepers.append(Sleeper(deadline: deadline, continuation: continuation))
            lock.unlock()
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        _now = _now.advanced(by: duration)
        let due = sleepers.filter { $0.deadline <= _now }
        sleepers.removeAll { $0.deadline <= _now }
        lock.unlock()
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}

@Suite
@MainActor
struct SidebarSelectionCoalescerTests {
    /// Lets the trailing Task (main-actor) run after a clock advance.
    private func drain() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test
    func firstRequestAppliesImmediately() async {
        let clock = SidebarTestManualClock()
        let coalescer = SidebarSelectionCoalescer(window: .milliseconds(100), clock: clock)
        var applied: [String] = []
        coalescer.request { applied.append("a") }
        #expect(applied == ["a"])
    }

    @Test
    func burstCollapsesToNewestOnTrailingEdge() async {
        let clock = SidebarTestManualClock()
        let coalescer = SidebarSelectionCoalescer(window: .milliseconds(100), clock: clock)
        var applied: [String] = []
        coalescer.request { applied.append("a") }
        clock.advance(by: .milliseconds(30))
        coalescer.request { applied.append("b") }
        clock.advance(by: .milliseconds(30))
        coalescer.request { applied.append("c") }
        #expect(applied == ["a"])

        clock.advance(by: .milliseconds(100))
        await drain()
        // Only the newest of the burst lands; the intermediate never applies.
        #expect(applied == ["a", "c"])
    }

    @Test
    func requestAfterQuietWindowIsImmediateAgain() async {
        let clock = SidebarTestManualClock()
        let coalescer = SidebarSelectionCoalescer(window: .milliseconds(100), clock: clock)
        var applied: [String] = []
        coalescer.request { applied.append("a") }
        clock.advance(by: .milliseconds(250))
        coalescer.request { applied.append("b") }
        #expect(applied == ["a", "b"])
    }

    @Test
    func cancelDropsPendingWithoutApplying() async {
        let clock = SidebarTestManualClock()
        let coalescer = SidebarSelectionCoalescer(window: .milliseconds(100), clock: clock)
        var applied: [String] = []
        coalescer.request { applied.append("a") }
        clock.advance(by: .milliseconds(10))
        coalescer.request { applied.append("b") }
        coalescer.cancel()
        clock.advance(by: .milliseconds(500))
        await drain()
        #expect(applied == ["a"])
    }

    @Test
    func flushAppliesPendingSynchronously() async {
        let clock = SidebarTestManualClock()
        let coalescer = SidebarSelectionCoalescer(window: .milliseconds(100), clock: clock)
        var applied: [String] = []
        coalescer.request { applied.append("a") }
        clock.advance(by: .milliseconds(10))
        // Plain click still inside the window: pending, not yet applied.
        coalescer.request { applied.append("b") }
        #expect(applied == ["a"])
        // A modifier click flushes the pending selection before extending
        // it ("click A, cmd-click B" must select both, not drop A).
        coalescer.flushNow()
        #expect(applied == ["a", "b"])
        // The cancelled trailing task must not double-apply.
        clock.advance(by: .milliseconds(500))
        await drain()
        #expect(applied == ["a", "b"])
    }

    @Test
    func flushWithNothingPendingIsANoOp() async {
        let clock = SidebarTestManualClock()
        let coalescer = SidebarSelectionCoalescer(window: .milliseconds(100), clock: clock)
        var applied: [String] = []
        coalescer.request { applied.append("a") }
        coalescer.flushNow()
        #expect(applied == ["a"])
    }
}
