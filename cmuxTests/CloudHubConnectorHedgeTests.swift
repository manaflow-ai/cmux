import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The fresh-machine connect policy: attempts started before a new VM is
/// reachable are lost, so later attempts must win without waiting for the
/// earlier ones' retransmit backoff.
@Suite
struct CloudHubConnectorHedgeTests {
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        private var discarded: [Int] = []
        func start() -> Int { lock.withLock { started += 1; return started } }
        func discard(_ value: Int) { lock.withLock { discarded.append(value) } }
        var startedCount: Int { lock.withLock { started } }
        var discardedValues: [Int] { lock.withLock { discarded } }
    }

    @Test("A redial wins as soon as the machine becomes reachable, while early attempts are still stuck")
    func laterAttemptWinsOverStuckEarlyAttempt() async throws {
        let ledger = Ledger()
        let reachableAt = ContinuousClock.now + .milliseconds(120)
        let started = ContinuousClock.now
        let value = try await CloudHubConnector.hedged(
            candidates: 1,
            fallbackDelay: .milliseconds(50),
            redialInterval: .milliseconds(20),
            maxRedials: 50,
            timeout: .seconds(10),
            clock: ContinuousClock(),
            attempt: { _ in
                let attempt = ledger.start()
                // An attempt started before the machine is reachable loses its
                // SYNs and would only succeed after a long backoff.
                if ContinuousClock.now < reachableAt {
                    try await Task.sleep(for: .seconds(10))
                }
                return attempt
            },
            discard: { ledger.discard($0) }
        )
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(1), "The winner must not wait for the stuck first attempt")
        #expect(value > 1)
        #expect(ledger.startedCount > 1)
    }

    @Test("Nothing reachable: fails at the deadline and stops redialing after the cap")
    func unreachableFailsAtDeadlineWithBoundedAttempts() async {
        let ledger = Ledger()
        await #expect(throws: (any Error).self) {
            _ = try await CloudHubConnector.hedged(
                candidates: 2,
                fallbackDelay: .milliseconds(5),
                redialInterval: .milliseconds(10),
                maxRedials: 3,
                timeout: .milliseconds(200),
                clock: ContinuousClock(),
                attempt: { _ -> Int in
                    _ = ledger.start()
                    try await Task.sleep(for: .seconds(10))
                    return 0
                },
                discard: { ledger.discard($0) }
            )
        }
        // One initial round plus three redials, for each of two addresses.
        #expect(ledger.startedCount == 8)
    }

    @Test("Every success other than the winner is discarded, so no stream leaks")
    func extraSuccessesAreDiscarded() async throws {
        let ledger = Ledger()
        let value = try await CloudHubConnector.hedged(
            candidates: 2,
            fallbackDelay: .zero,
            redialInterval: .milliseconds(5),
            maxRedials: 5,
            timeout: .seconds(5),
            clock: ContinuousClock(),
            attempt: { index in
                let attempt = ledger.start()
                // Both addresses answer; cancellation is ignored to model a
                // handshake that completes while the race is being decided.
                try? await Task.sleep(for: .milliseconds(30))
                return attempt * 10 + index
            },
            discard: { ledger.discard($0) }
        )
        #expect(!ledger.discardedValues.contains(value))
        #expect(ledger.discardedValues.count == ledger.startedCount - 1)
    }
}
