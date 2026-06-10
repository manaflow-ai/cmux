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
    /// Both phases poll observable conditions through `XCTNSPredicateExpectation`
    /// instead of a hand-rolled deadline loop, so each waits only as long as it
    /// needs to and never longer than its bound.
    ///
    /// - Parameters:
    ///   - listenerBindTimeout: Maximum time to wait for the socket file to
    ///     appear (the listener-bound signal). Generous on purpose so a slow
    ///     launch does not eat the ping budget; only hit on a genuine bind
    ///     failure.
    ///   - pingTimeout: Fresh budget for the `ping` -> `PONG` round trip once
    ///     the listener has bound.
    ///   - socketFileExists: Returns true once the listener's socket file is on
    ///     disk. A closure (not a path) so callers that resolve among several
    ///     candidate paths can report "any candidate exists".
    ///   - pingReturnsPong: Returns true when a `ping` to the listener answered
    ///     `PONG`.
    /// - Returns: `true` only when both phases complete.
    func waitForControlSocketReady(
        listenerBindTimeout: TimeInterval = 60.0,
        pingTimeout: TimeInterval,
        socketFileExists: @escaping () -> Bool,
        pingReturnsPong: @escaping () -> Bool
    ) -> Bool {
        let bound = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in socketFileExists() },
            object: nil
        )
        guard XCTWaiter().wait(for: [bound], timeout: listenerBindTimeout) == .completed else {
            return false
        }

        let responsive = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in pingReturnsPong() },
            object: nil
        )
        return XCTWaiter().wait(for: [responsive], timeout: pingTimeout) == .completed
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
