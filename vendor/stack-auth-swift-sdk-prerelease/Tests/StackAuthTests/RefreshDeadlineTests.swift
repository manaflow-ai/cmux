import Foundation
import Testing
@testable import StackAuth

@Suite struct RefreshDeadlineTests {
    @Test(arguments: [true, false])
    func elapsedDeadlineWinsEvenWhenResponseRunsBeforeWakeTimer(wakeTimer: Bool) async {
        let clock = RefreshTestClock()
        let owner = TokenRefreshCoordinator()
        let store = MemoryTokenStore()
        let gate = RefreshExchangeGate()
        await store.setTokens(accessToken: "expired", refreshToken: "session")
        let request = Task {
            await owner.resolve(store: store, refreshToken: "session", accessToken: "expired",
                clock: adapted(clock), timeoutNanoseconds: 2_000_000_000) { await gate.exchange() }
        }
        await gate.waitUntilStarted()
        await clock.waitUntilSleepers()
        // Models a wake where the response runs before the deadline task. It
        // proves ordering independence; it does not claim a physical system sleep.
        clock.advance(by: .seconds(600), wakeSleepers: wakeTimer)
        if !wakeTimer { await gate.release(.success(accessToken: "late")) }
        let result = await request.value
        #expect(result.refreshFailure == .timedOut)
        #expect(await store.getStoredAccessToken() == "expired")
        #expect(await store.getStoredRefreshToken() == "session")
        if wakeTimer { await gate.release(.success(accessToken: "late")) }

        let retry = await owner.resolve(store: store, refreshToken: "session", accessToken: "expired",
            clock: adapted(clock), timeoutNanoseconds: 2_000_000_000) { .success(accessToken: "recovered") }
        #expect(retry.accessToken == "recovered")
        #expect(await store.getStoredAccessToken() == "recovered")
    }

    @Test func lastCancelledWaiterReleasesAttemptAndLateWorkCannotPublish() async {
        let clock = RefreshTestClock()
        let owner = TokenRefreshCoordinator()
        let store = MemoryTokenStore()
        let gate = RefreshExchangeGate()
        await store.setTokens(accessToken: "expired", refreshToken: "session")
        let request = Task {
            await owner.resolve(store: store, refreshToken: "session", accessToken: "expired",
                clock: adapted(clock), timeoutNanoseconds: 2_000_000_000) { await gate.exchange() }
        }
        await gate.waitUntilStarted()
        request.cancel()
        #expect(await request.value.refreshFailure == .cancelled)
        let retry = await owner.resolve(store: store, refreshToken: "session", accessToken: "expired",
            clock: adapted(clock), timeoutNanoseconds: 2_000_000_000) { .success(accessToken: "recovered") }
        await gate.release(.success(accessToken: "late"))
        #expect(retry.accessToken == "recovered")
        #expect(await store.getStoredAccessToken() == "recovered")
    }

    @Test(arguments: [200, 401, 503])
    func refreshClassifiesSuccessRejectionAndTransientFailure(status: Int) async {
        let fixture = RefreshTransportFixture()
        let session = await fixture.session()
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "expired", refreshToken: "session")
        let client = APIClient(baseUrl: "https://" + fixture.host, projectId: "fixture", publishableClientKey: "synthetic", tokenStore: store, session: session)
        await fixture.release(status: status, token: RefreshLifecycleTests.fresh)
        let pair = await client.getOrFetchLikelyValidTokens()
        #expect(pair.accessToken == (status == 200 ? RefreshLifecycleTests.fresh : nil))
        #expect(await store.getStoredRefreshToken() == (status == 401 ? nil : "session"))
        #expect(await fixture.count == 1)
        session.invalidateAndCancel()
        await fixture.close()
    }

    @Test(arguments: [true, false])
    func deadlinePreservesUsableTokenOnlyForProactiveRefresh(force: Bool) async {
        let clock = RefreshTestClock()
        let fixture = RefreshTransportFixture()
        let session = await fixture.session()
        let store = MemoryTokenStore()
        // iat is old (proactive refresh needed), exp is still far in the future.
        let usable = "eyJhbGciOiJIUzI1NiJ9.eyJpYXQiOjEsImV4cCI6OTk5OTk5OTk5OX0.synthetic"
        await store.setTokens(accessToken: usable, refreshToken: "session")
        let client = APIClient(baseUrl: "https://" + fixture.host, projectId: "fixture", publishableClientKey: "synthetic",
            tokenStore: store, session: session, refreshClock: adapted(clock), refreshTimeoutNanoseconds: 2_000_000_000)
        let request = Task {
            await (force ? client.fetchNewAccessToken() : client.getOrFetchLikelyValidTokens())
        }
        await fixture.waitForRequest()
        await clock.waitUntilSleepers()
        clock.advance(by: .seconds(2))
        let result = await request.value
        #expect(result.accessToken == (force ? nil : usable))
        #expect(result.refreshFailure == (force ? .timedOut : nil))
        #expect(await store.getStoredAccessToken() == usable)
        #expect(await store.getStoredRefreshToken() == "session")
        session.invalidateAndCancel()
        await fixture.close()
    }

    @Test func delayedTimerRegistrationDoesNotRestartTheBudget() async {
        let clock = RefreshTestClock()
        let underlying = adapted(clock)
        let registration = RefreshTimerRegistrationGate()
        let delayedClock = TokenRefreshClock(now: underlying.now, sleepUntil: { deadline in
            await registration.park()
            try await underlying.sleepUntil(deadline)
        })
        let owner = TokenRefreshCoordinator()
        let store = MemoryTokenStore()
        let exchange = RefreshExchangeGate()
        await store.setTokens(accessToken: "expired", refreshToken: "session")
        let request = Task {
            await owner.resolve(store: store, refreshToken: "session", accessToken: "expired",
                clock: delayedClock, timeoutNanoseconds: 2_000_000_000) { await exchange.exchange() }
        }
        await exchange.waitUntilStarted()
        await registration.waitUntilParked()
        clock.advance(by: .seconds(600))
        await registration.release()
        #expect(await request.value.refreshFailure == .timedOut)
        await exchange.release(.success(accessToken: "late"))
        #expect(await store.getStoredAccessToken() == "expired")
    }

    private func adapted(_ clock: RefreshTestClock) -> TokenRefreshClock {
        TokenRefreshClock(now: {
            let parts = clock.now.offset.components
            return UInt64(parts.seconds) * 1_000_000_000 + UInt64(parts.attoseconds / 1_000_000_000)
        }, sleepUntil: { try await clock.sleep(until: .init(offset: .nanoseconds(Int64($0))), tolerance: nil) })
    }
}
