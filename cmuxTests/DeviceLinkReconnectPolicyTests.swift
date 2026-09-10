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
        #expect(policy.apply(.connectFailed(retryable: true, reason: "refused")) == .waiting(attempt: 1, delay: .seconds(1)))
        #expect(policy.apply(.waitElapsed) == .connecting(attempt: 2))
        #expect(policy.apply(.connectFailed(retryable: true, reason: "refused")) == .waiting(attempt: 2, delay: .seconds(2)))
        #expect(policy.apply(.waitElapsed) == .connecting(attempt: 3))
        #expect(policy.apply(.connectFailed(retryable: true, reason: "refused")) == .waiting(attempt: 3, delay: .seconds(5)))
        #expect(policy.apply(.waitElapsed) == .connecting(attempt: 4))
        #expect(policy.apply(.connectSucceeded) == .connected)
        #expect(policy.apply(.transportLost) == .connecting(attempt: 1), "a recovered link resets the attempt count")
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
        _ = policy.apply(.connectFailed(retryable: true, reason: "x"))
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
        _ = policy.apply(.directory(dialable: true))
        #expect(policy.apply(.connectFailed(retryable: false, reason: "other account")) == .blocked(reason: "other account"))
        #expect(policy.apply(.waitElapsed) == .blocked(reason: "other account"))
        #expect(policy.apply(.transportLost) == .blocked(reason: "other account"))
        #expect(policy.apply(.refreshRequested) == .connecting(attempt: 1))
        _ = policy.apply(.connectSucceeded)
        #expect(policy.apply(.refreshRequested) == .connected, "refresh does not tear down a healthy link")
        #expect(policy.apply(.stopped) == .idle)
        #expect(policy.apply(.connectSucceeded) == .idle, "a late success after stop is ignored")
        #expect(policy.apply(.refreshRequested) == .connecting(attempt: 1), "the directory verdict survives a stop")
        _ = policy.apply(.connectFailed(retryable: false, reason: "blocked"))
        #expect(policy.apply(.directory(dialable: true)) == .connecting(attempt: 1), "a presence change is the other way out of blocked")
    }

    @Test("A failure that lands after the device went offline idles instead of waiting")
    func failureAfterOffline() {
        var policy = DeviceLinkReconnectPolicy()
        _ = policy.apply(.directory(dialable: true))
        #expect(policy.apply(.directory(dialable: false)) == .idle)
        #expect(policy.apply(.connectFailed(retryable: true, reason: "x")) == .idle)
        #expect(policy.apply(.connectSucceeded) == .idle)
    }
}
