import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The recovery contract of one device link, as the pure reducer states it: a
/// network blip or remote relaunch redials at once, repeated failures back off
/// to a bounded ceiling, presence drops park the link, and a non-retryable
/// failure blocks until something about the device changes.
@Suite("Devices: link reconnect policy")
struct DeviceLinkReconnectPolicyTests {
    private func failure(_ kind: DeviceLinkFailure.Kind, _ message: String) -> DeviceLinkFailure {
        DeviceLinkFailure(kind: kind, code: kind.rawValue, message: message)
    }

    @Test("Repeated connect-and-close cycles back off after the first immediate retry")
    func flappingTransportBacksOff() {
        var policy = DeviceLinkReconnectPolicy()
        _ = policy.apply(.directory(dialable: true))
        _ = policy.apply(.connectSucceeded)
        #expect(policy.apply(.transportLost) == .connecting(attempt: 1))
        for failure in 1...8 {
            _ = policy.apply(.connectSucceeded)
            #expect(policy.apply(.transportLost) == .waiting(
                attempt: failure, delay: DeviceLinkReconnectPolicy.delay(afterFailures: failure)
            ))
            _ = policy.apply(.waitElapsed)
        }
    }

    @Test("A dialable device connects; a live link that drops redials at once, then backs off")
    func connectLoseRetry() {
        var policy = DeviceLinkReconnectPolicy()
        #expect(policy.phase == .idle)
        #expect(policy.apply(.directory(dialable: true)) == .connecting(attempt: 1))
        #expect(policy.apply(.connectSucceeded) == .connected)
        #expect(policy.apply(.transportLost) == .connecting(attempt: 1), "a blip or remote restart redials immediately")
        #expect(policy.apply(.connectFailed(failure(.transient, "refused"))) == .waiting(attempt: 1, delay: .seconds(1)))
        #expect(policy.apply(.waitElapsed) == .connecting(attempt: 2))
        #expect(policy.apply(.connectFailed(failure(.transient, "refused"))) == .waiting(attempt: 2, delay: .seconds(2)))
        #expect(policy.apply(.waitElapsed) == .connecting(attempt: 3))
        #expect(policy.apply(.connectFailed(failure(.transient, "refused"))) == .waiting(attempt: 3, delay: .seconds(5)))
        #expect(policy.apply(.waitElapsed) == .connecting(attempt: 4))
        let recoveredAt = Date(timeIntervalSince1970: 1_000)
        #expect(policy.apply(.connectSucceeded, now: recoveredAt) == .connected)
        #expect(
            policy.apply(.transportLost, now: recoveredAt.addingTimeInterval(DeviceLinkReconnectPolicy.stableConnectionInterval)) == .connecting(attempt: 1),
            "a stable recovered link resets the attempt count"
        )
    }

    @Test("Backoff is bounded at thirty seconds")
    func backoffTable() {
        #expect(DeviceLinkReconnectPolicy.delay(afterFailures: 0) == .seconds(1))
        #expect(DeviceLinkReconnectPolicy.delay(afterFailures: 1) == .seconds(1))
        #expect(DeviceLinkReconnectPolicy.delay(afterFailures: 2) == .seconds(2))
        #expect(DeviceLinkReconnectPolicy.delay(afterFailures: 4) == .seconds(10))
        #expect(DeviceLinkReconnectPolicy.delay(afterFailures: 5) == .seconds(30))
        #expect(DeviceLinkReconnectPolicy.delay(afterFailures: 50) == .seconds(30))
        #expect(DeviceLinkReconnectPolicy.delays.last == .seconds(30))
    }

    @Test("A presence drop parks the link; coming back online redials from the first attempt")
    func presenceEdges() {
        var policy = DeviceLinkReconnectPolicy()
        _ = policy.apply(.directory(dialable: true))
        _ = policy.apply(.connectFailed(failure(.transient, "x")))
        #expect(policy.apply(.directory(dialable: false)) == .idle)
        #expect(policy.isDialable == false)
        #expect(policy.apply(.waitElapsed) == .idle, "a stale wait never redials an offline device")
        #expect(policy.apply(.transportLost) == .idle)
        #expect(policy.apply(.refreshRequested) == .idle, "refresh cannot dial an offline device")
        #expect(policy.apply(.directory(dialable: true)) == .connecting(attempt: 1))
        #expect(policy.apply(.directory(dialable: true)) == .connecting(attempt: 1), "repeat presence ticks do not restart a dial")
        _ = policy.apply(.connectSucceeded)
        #expect(policy.apply(.directory(dialable: true)) == .connected, "a presence tick never tears down a live link")
    }

    @Test("Non-retryable failures block until a refresh or presence change; stop always idles")
    func blockedAndStopped() {
        var policy = DeviceLinkReconnectPolicy()
        let otherAccount = failure(.identity, "other account")
        _ = policy.apply(.directory(dialable: true))
        #expect(policy.apply(.connectFailed(otherAccount)) == .blocked(otherAccount))
        #expect(policy.apply(.waitElapsed) == .blocked(otherAccount))
        #expect(policy.apply(.transportLost) == .blocked(otherAccount))
        #expect(policy.apply(.directoryRevisionAdvanced) == .blocked(otherAccount), "a new directory revision cannot change an identity verdict")
        #expect(policy.apply(.refreshRequested) == .connecting(attempt: 1))
        _ = policy.apply(.connectSucceeded)
        #expect(policy.apply(.refreshRequested) == .connected, "refresh does not tear down a healthy link")
        #expect(policy.apply(.stopped) == .idle)
        #expect(policy.apply(.connectSucceeded) == .idle, "a late success after stop is ignored")
        #expect(policy.apply(.refreshRequested) == .connecting(attempt: 1), "the directory verdict survives a stop")
        let blocked = failure(.unsupported, "blocked")
        _ = policy.apply(.connectFailed(blocked))
        #expect(policy.apply(.directory(dialable: true)) == .blocked(blocked), "ordinary directory updates cannot retry an identity rejection")
        #expect(policy.apply(.directory(dialable: false)) == .idle)
        #expect(policy.apply(.directory(dialable: true)) == .connecting(attempt: 1), "a real dialability change permits a new attempt")
    }

    @Test("A failure that lands after the device went offline idles instead of waiting")
    func failureAfterOffline() {
        var policy = DeviceLinkReconnectPolicy()
        _ = policy.apply(.directory(dialable: true))
        #expect(policy.apply(.directory(dialable: false)) == .idle)
        #expect(policy.apply(.connectFailed(failure(.transient, "x"))) == .idle)
        #expect(policy.apply(.connectSucceeded) == .idle)
    }

    @Test("The other Mac's refusal parks the link; only a new directory revision, a refresh, or a dialability change retries it")
    func hostRefusalRetriesOnDirectoryRevision() {
        var policy = DeviceLinkReconnectPolicy()
        let refusal = failure(.hostDenied, "Studio has not authorized this Mac.")
        _ = policy.apply(.directory(dialable: true))
        #expect(policy.apply(.connectFailed(refusal)) == .blocked(refusal))
        #expect(policy.apply(.waitElapsed) == .blocked(refusal), "no timer redials a refusal")
        #expect(policy.apply(.directory(dialable: true)) == .blocked(refusal), "presence ticks do not redial a refusal")
        #expect(policy.apply(.directoryRevisionAdvanced) == .connecting(attempt: 1), "the control plane re-issued permissions")
        #expect(policy.apply(.connectFailed(refusal)) == .blocked(refusal))
        #expect(policy.apply(.refreshRequested) == .connecting(attempt: 1))
        _ = policy.apply(.connectFailed(refusal))
        #expect(policy.apply(.directory(dialable: false)) == .idle)
        #expect(policy.apply(.directoryRevisionAdvanced) == .idle, "an undialable device never redials")
    }

    @Test("A directory precondition parks the link without a dial and releases it when the directory satisfies it")
    func controlPlanePrecondition() {
        var policy = DeviceLinkReconnectPolicy()
        let outdated = DeviceLinkFailure.controlPlaneOutdated()
        #expect(policy.apply(.directory(dialable: true, precondition: outdated)) == .blocked(outdated))
        #expect(policy.apply(.waitElapsed) == .blocked(outdated))
        #expect(policy.apply(.directoryRevisionAdvanced) == .blocked(outdated), "a revision that still lacks the rule changes nothing")
        #expect(policy.apply(.refreshRequested) == .blocked(outdated), "an explicit refresh cannot override what the directory proved")
        #expect(policy.apply(.directory(dialable: true)) == .connecting(attempt: 1), "the directory now names the rule")
        _ = policy.apply(.connectFailed(failure(.transient, "blip")))
        #expect(policy.apply(.refreshRequested) == .connecting(attempt: 1), "with the precondition cleared, refresh retries as before")
        #expect(policy.apply(.directory(dialable: true, precondition: outdated)) == .blocked(outdated), "a dial in flight is abandoned")
        _ = policy.apply(.directory(dialable: true))
        _ = policy.apply(.connectSucceeded)
        #expect(policy.apply(.directory(dialable: true, precondition: outdated)) == .connected, "a live link is proof the precondition is stale")
        #expect(policy.apply(.transportLost) == .blocked(outdated), "once that link is gone the precondition governs; no redial")
        #expect(policy.apply(.refreshRequested) == .blocked(outdated))
        #expect(policy.apply(.directory(dialable: false, precondition: outdated)) == .idle)
    }
}
