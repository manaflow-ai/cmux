import XCTest
import Foundation

extension XCTestCase {
    /// Waits for a cmux control socket listener to become ready in two
    /// decoupled phases, then returns whether it answered a `ping` with `PONG`.
    ///
    /// The two phases exist to keep a slow app cold-launch on hosted CI runners
    /// from starving the ping budget:
    ///
    /// 1. **Listener bound.** Wait up to `listenerBindTimeout` for the listener
    ///    to bind, observed as the Unix-domain socket file appearing on disk.
    ///    The server creates that file with `bind(2)` before it accepts, so the
    ///    file appearing is a real readiness signal, not a fixed sleep. Each UI
    ///    test binds a unique per-run socket path and removes it in `setUp`, so
    ///    the file can only appear because *this* app instance bound it.
    /// 2. **Accepting and responsive.** With the listener bound, wait up to
    ///    `pingTimeout` (a *fresh* budget that only starts once phase 1
    ///    completes) for it to accept a connection and answer `ping` with
    ///    `PONG`.
    ///
    /// Splitting the wait this way is the fix for the flake in
    /// https://github.com/manaflow-ai/cmux/issues/5414: previously a single
    /// fixed `pingTimeout` had to cover *both* the time for the listener to
    /// bind and the time to answer, so a slow cold-launch could exhaust the
    /// whole budget before the listener even existed. Now a slow launch is
    /// absorbed by `listenerBindTimeout` and the ping confirmation always gets
    /// its full budget.
    ///
    /// Both phases poll their condition on a fixed cadence with a deterministic
    /// deadline loop (``pollControlSocketCondition``), re-evaluating every
    /// ``pollInterval`` until the bound elapses.
    ///
    /// This deliberately does *not* use `XCTNSPredicateExpectation`. That class
    /// is unreliable here because the conditions are non-KVO closures that do
    /// blocking socket I/O: the ping closure opens a connection and blocks up to
    /// its response timeout on every evaluation. `XCTNSPredicateExpectation`
    /// evaluates such a predicate once, then relies on a polling timer scheduled
    /// on the run loop to re-evaluate; under `XCTWaiter.wait` that re-poll can be
    /// starved, so a single early `false` (the listener bound but its accept
    /// loop not yet answering, a sub-second window) makes the waiter sit on the
    /// stale `false` for the full timeout even though the socket became
    /// responsive almost immediately. That is the flake seen in CI on
    /// `BrowserPaneNavigationKeybindUITests` (issue surfaced 2026-06-13): the
    /// app's own sanity check reported `PONG` ~1s after launch, yet the test's
    /// 12s ping wait failed. A plain deadline loop guarantees the ping is
    /// actually retried for the whole budget. See also
    /// https://github.com/manaflow-ai/cmux/issues/5414 for the two-phase split.
    ///
    /// - Parameters:
    ///   - listenerBindTimeout: Maximum time to wait for the socket file to
    ///     appear (the listener-bound signal). Generous on purpose so a slow
    ///     launch does not eat the ping budget; only hit on a genuine bind
    ///     failure.
    ///   - pingTimeout: Fresh budget for the `ping` -> `PONG` round trip once
    ///     the listener has bound.
    ///   - pollInterval: How long to wait between condition re-evaluations.
    ///   - socketFileExists: Returns true once the listener's socket file is on
    ///     disk. A closure (not a path) so callers that resolve among several
    ///     candidate paths can report "any candidate exists".
    ///   - pingReturnsPong: Returns true when a `ping` to the listener answered
    ///     `PONG`.
    /// - Returns: `true` only when both phases complete.
    func waitForControlSocketReady(
        listenerBindTimeout: TimeInterval = 60.0,
        pingTimeout: TimeInterval,
        pollInterval: TimeInterval = 0.2,
        socketFileExists: @escaping () -> Bool,
        pingReturnsPong: @escaping () -> Bool
    ) -> Bool {
        guard pollControlSocketCondition(
            timeout: listenerBindTimeout,
            pollInterval: pollInterval,
            condition: socketFileExists
        ) else {
            return false
        }
        return pollControlSocketCondition(
            timeout: pingTimeout,
            pollInterval: pollInterval,
            condition: pingReturnsPong
        )
    }

    /// Polls `condition` until it returns true or `timeout` elapses, spinning
    /// the current run loop for `pollInterval` between attempts so the app
    /// process keeps making progress without busy-waiting. The condition may
    /// block (e.g. a socket round trip); the deadline still bounds total wait.
    private func pollControlSocketCondition(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        } while Date() < deadline
        // One final attempt right at the deadline so a condition that became
        // true during the last sleep is not missed.
        return condition()
    }

    /// Convenience wrapper of ``waitForControlSocketReady(listenerBindTimeout:pingTimeout:socketFileExists:pingReturnsPong:)``
    /// for the common single-path case: the listener-bound signal is simply the
    /// file at `socketPath` appearing. `pingReturnsPong` is a trailing closure
    /// so call sites stay as terse as the previous single-budget poll.
    func waitForControlSocketReady(
        socketPath: String,
        listenerBindTimeout: TimeInterval = 60.0,
        pingTimeout: TimeInterval,
        pingReturnsPong: @escaping () -> Bool
    ) -> Bool {
        waitForControlSocketReady(
            listenerBindTimeout: listenerBindTimeout,
            pingTimeout: pingTimeout,
            socketFileExists: { FileManager.default.fileExists(atPath: socketPath) },
            pingReturnsPong: pingReturnsPong
        )
    }
}
