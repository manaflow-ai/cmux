import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import StackAuth

/// Records the SDK's process-wide rate-limit signals for one test.
private final class RefreshSignalRecorder: StackAuthRateLimitObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var refreshObservations: [StackAuthRateLimitObservation] = []
    private var recoveries = 0

    func stackAuthDidRateLimit(_ observation: StackAuthRateLimitObservation) {
        guard observation.isTokenRefresh else { return }
        lock.lock(); refreshObservations.append(observation); lock.unlock()
    }
    func stackAuthTokenRefreshDidRecover() { lock.lock(); recoveries += 1; lock.unlock() }
    func stackAuthRequestDidSucceed() {}

    var snapshot: (observations: [StackAuthRateLimitObservation], recoveries: Int) {
        lock.lock(); defer { lock.unlock() }
        return (refreshObservations, recoveries)
    }
}

extension RateLimitRetryTests {
    /// A 429 on the refresh exchange is reported once with the cooldown the
    /// SDK chose; calls inside the cooldown report nothing; the first
    /// successful exchange after it reports a recovery.
    @Test func rateLimitedRefreshIsObservedOnceThenRecovers() async {
        let recorder = RefreshSignalRecorder()
        StackAuthRateLimitReporting.setObserver(recorder)
        defer { StackAuthRateLimitReporting.setObserver(nil) }
        let clock = RefreshTestClock()
        let fixture = RefreshTransportFixture()
        let session = await fixture.session()
        let store = MemoryTokenStore()
        // Inside the refresh lead (a proactive refresh is due) but not expired.
        let now = Int(Date().timeIntervalSince1970)
        let claims = Data("{\"iat\":\(now - 1000),\"exp\":\(now + 30)}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let usable = "eyJhbGciOiJIUzI1NiJ9.\(claims).synthetic"
        await store.setTokens(accessToken: usable, refreshToken: "session")
        let client = APIClient(
            baseUrl: "https://" + fixture.host, projectId: "fixture", publishableClientKey: "synthetic",
            tokenStore: store, session: session, refreshClock: testClock(clock), refreshTimeoutNanoseconds: 2_000_000_000
        )

        await fixture.release(status: 429, token: "unused")
        #expect(await client.getOrFetchLikelyValidTokens().accessToken == usable)
        #expect(await client.getOrFetchLikelyValidTokens().accessToken == usable)
        #expect(await fixture.count == 1)

        // Past the longest first cooldown without Retry-After (5 s).
        clock.advance(by: .seconds(6))
        await fixture.release(status: 200, token: RefreshLifecycleTests.fresh)
        #expect(await client.getOrFetchLikelyValidTokens().accessToken == RefreshLifecycleTests.fresh)
        #expect(await fixture.count == 2)

        let (observations, recoveries) = recorder.snapshot
        #expect(observations.count == 1)
        #expect(observations.first?.endpoint == "/api/v1/auth/oauth/token")
        #expect(observations.first?.bodyKind == .json)
        #expect(observations.first?.retryAfterSeconds == nil)
        #expect(observations.first?.refreshAttempt == 1)
        #expect((2.5...5).contains(observations.first?.refreshBackoffSeconds ?? -1))
        #expect(recoveries == 1)
        session.invalidateAndCancel()
        await fixture.close()
    }

    private func testClock(_ clock: RefreshTestClock) -> TokenRefreshClock {
        TokenRefreshClock(now: {
            let parts = clock.now.offset.components
            return UInt64(parts.seconds) * 1_000_000_000 + UInt64(parts.attoseconds / 1_000_000_000)
        }, sleepUntil: { try await clock.sleep(until: .init(offset: .nanoseconds(Int64($0))), tolerance: nil) })
    }
}
