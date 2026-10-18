import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A restored `cmux ssh` workspace must stay connecting while its attach
/// retries, and report an error only once retrying cannot help.
@MainActor
@Suite("SSH cmux-tui restore attach retry", .serialized)
struct SSHTuiAttachRetryTests {
    private struct TransientFailure: Error {}

    private let policy = SSHTuiAttachRetryPolicy(delays: [.seconds(1), .seconds(2)])

    @Test("Retryable failures back off on the schedule, then give up")
    func retryScheduleIsBounded() {
        let error = CloudMachineLink.LinkError.failureMessage("ssh: Could not resolve hostname host")
        #expect(policy.retryDelay(afterFailure: 1, error: error) == .seconds(1))
        #expect(policy.retryDelay(afterFailure: 2, error: error) == .seconds(2))
        #expect(policy.retryDelay(afterFailure: 3, error: error) == nil)
    }

    @Test("Failures that no retry can fix report at once")
    func permanentFailuresAreNotRetried() {
        #expect(policy.retryDelay(afterFailure: 1, error: CloudDiagnosticFailure.unsupported) == nil)
        #expect(policy.retryDelay(afterFailure: 1, error: CloudMachineLink.LinkError.clientMissing) == nil)
        #expect(policy.retryDelay(afterFailure: 1, error: CancellationError()) == nil)
        // The carrier already spent its connect deadline; report instead of another lap.
        #expect(policy.retryDelay(afterFailure: 1, error: CloudMachineLink.LinkError.timedOut) == nil)
        #expect(policy.retryDelay(afterFailure: 1, error: CloudMachineLink.LinkError.requestTimedOut) == .seconds(1))
        // A spent carrier deadline is reported, but still retried quietly afterwards.
        #expect(!SSHTuiAttachRetryPolicy.isPermanent(CloudMachineLink.LinkError.timedOut))
        #expect(SSHTuiAttachRetryPolicy.isPermanent(CloudDiagnosticFailure.unsupported))
        #expect(SSHTuiAttachRetryPolicy.isPermanent(CloudMachineLink.LinkError.clientMissing))
        #expect(!SSHTuiAttachRetryPolicy.isPermanent(CloudMachineLink.LinkError.failureMessage("Connection refused")))
    }

    @Test("Only a link that came up after the failure retries early")
    func linkUpRetriesOnlyAfterADownLink() {
        #expect(SSHTuiAttachRetryPolicy.shouldRetryNow(linkWasConnectedAtFailure: false, linkState: .connected))
        #expect(!SSHTuiAttachRetryPolicy.shouldRetryNow(linkWasConnectedAtFailure: true, linkState: .connected))
        #expect(!SSHTuiAttachRetryPolicy.shouldRetryNow(linkWasConnectedAtFailure: false, linkState: .connecting))
        #expect(!SSHTuiAttachRetryPolicy.shouldRetryNow(linkWasConnectedAtFailure: false, linkState: .error))
        #expect(!SSHTuiAttachRetryPolicy.shouldRetryNow(linkWasConnectedAtFailure: false, linkState: nil))
    }

    @Test("A transient failure retries after its backoff and connects without reporting")
    func transientFailureConnectsOnRetry() async {
        let clock = CloudReadManualClock()
        let backoff = SSHTuiAttachBackoff()
        var attempts = 0
        var keptPending: [Bool] = []
        var failures = 0
        var retries = 0
        let run = Task { @MainActor in
            await SSHTuiAttachRetry.run(
                policy: policy, clock: clock, backoff: backoff,
                failed: { _ in failures += 1 },
                retrying: { retries += 1 },
                attempt: { willRetry in
                    attempts += 1
                    if attempts == 1 {
                        keptPending.append(willRetry(TransientFailure()))
                        throw TransientFailure()
                    }
                }
            )
        }
        await waitUntil { clock.pendingSleeperCount == 1 }
        #expect(attempts == 1)
        #expect(failures == 1)
        clock.advance(by: .seconds(1))
        let outcome = await run.value
        guard case .connected = outcome else {
            Issue.record("expected connected, got \(outcome)")
            return
        }
        #expect(attempts == 2)
        #expect(retries == 1)
        #expect(keptPending == [true])
    }

    @Test("Failures that outlast the schedule report the last error")
    func exhaustedRetriesFail() async {
        let clock = CloudReadManualClock()
        let backoff = SSHTuiAttachBackoff()
        var attempts = 0
        var lastKeptPending: Bool?
        let run = Task { @MainActor in
            await SSHTuiAttachRetry.run(policy: policy, clock: clock, backoff: backoff) { willRetry in
                attempts += 1
                lastKeptPending = willRetry(TransientFailure())
                throw TransientFailure()
            }
        }
        await waitUntil { clock.pendingSleeperCount == 1 }
        clock.advance(by: .seconds(1))
        await waitUntil { attempts == 2 && clock.pendingSleeperCount == 1 }
        clock.advance(by: .seconds(2))
        let outcome = await run.value
        guard case .failed(let error) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(error is TransientFailure)
        #expect(attempts == 3)
        // The final attempt fails its reserved pane instead of keeping it pending.
        #expect(lastKeptPending == false)
    }

    @Test("A permanent failure reports on the first attempt without waiting")
    func permanentFailureFailsImmediately() async {
        let clock = CloudReadManualClock()
        var attempts = 0
        let outcome = await SSHTuiAttachRetry.run(policy: policy, clock: clock, backoff: SSHTuiAttachBackoff()) { _ in
            attempts += 1
            throw CloudDiagnosticFailure.unsupported
        }
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(attempts == 1)
        #expect(clock.pendingSleeperCount == 0)
    }

    @Test("A link-up wake retries before the backoff elapses")
    func wakeEndsBackoffEarly() async {
        let clock = CloudReadManualClock()
        let backoff = SSHTuiAttachBackoff()
        var attempts = 0
        let run = Task { @MainActor in
            await SSHTuiAttachRetry.run(
                policy: SSHTuiAttachRetryPolicy(delays: [.seconds(600)]), clock: clock, backoff: backoff
            ) { _ in
                attempts += 1
                if attempts == 1 { throw TransientFailure() }
            }
        }
        await waitUntil { clock.pendingSleeperCount == 1 }
        backoff.wake()
        let outcome = await run.value
        guard case .connected = outcome else {
            Issue.record("expected connected, got \(outcome)")
            return
        }
        #expect(attempts == 2)
        #expect(clock.now.offset == .zero)
    }

    @Test("A wake that lands before the wait begins is not lost")
    func wakeBeforeWaitIsKept() async {
        let clock = CloudReadManualClock()
        let backoff = SSHTuiAttachBackoff()
        var attempts = 0
        let outcome = await SSHTuiAttachRetry.run(
            policy: SSHTuiAttachRetryPolicy(delays: [.seconds(600)]), clock: clock, backoff: backoff,
            failed: { _ in backoff.wake() }
        ) { _ in
            attempts += 1
            if attempts == 1 { throw TransientFailure() }
        }
        guard case .connected = outcome else {
            Issue.record("expected connected, got \(outcome)")
            return
        }
        #expect(attempts == 2)
    }

    @Test("Cancelling the attach ends a backoff wait without reporting")
    func cancellationEndsQuietly() async {
        let clock = CloudReadManualClock()
        let backoff = SSHTuiAttachBackoff()
        var attempts = 0
        let run = Task { @MainActor in
            await SSHTuiAttachRetry.run(policy: policy, clock: clock, backoff: backoff) { _ in
                attempts += 1
                throw TransientFailure()
            }
        }
        await waitUntil { clock.pendingSleeperCount == 1 }
        run.cancel()
        let outcome = await run.value
        guard case .cancelled = outcome else {
            Issue.record("expected cancelled, got \(outcome)")
            return
        }
        #expect(attempts == 1)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
        #expect(condition())
    }
}
