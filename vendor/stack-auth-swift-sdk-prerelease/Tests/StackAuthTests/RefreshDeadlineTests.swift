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

    private func adapted(_ clock: RefreshTestClock) -> TokenRefreshClock {
        TokenRefreshClock(now: {
            let parts = clock.now.offset.components
            return UInt64(parts.seconds) * 1_000_000_000 + UInt64(parts.attoseconds / 1_000_000_000)
        }, sleep: { try await clock.sleep(for: .nanoseconds(Int64($0))) })
    }
}
