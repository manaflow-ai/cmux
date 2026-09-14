import Foundation
import Testing
@testable import StackAuth

@Suite struct RefreshTransportTimingTests {
    @Test func realTransportWaitHasATotalDeadline() async {
        let fixture = RefreshTransportFixture()
        let session = await fixture.session()
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "expired", refreshToken: "session")
        let client = APIClient(baseUrl: "https://" + fixture.host, projectId: "fixture", publishableClientKey: "synthetic", tokenStore: store, session: session,
            refreshTimeoutNanoseconds: 100_000_000)
        let start = ContinuousClock.now
        let active = SuspendingClock.now
        let result = await client.getOrFetchLikelyValidTokens()
        let elapsed = start.duration(to: .now)
        let awake = active.duration(to: .now)
        #expect(result.refreshFailure == .timedOut)
        #expect(elapsed >= .milliseconds(100))
        #expect(elapsed < .seconds(2))
        #expect(await store.getStoredRefreshToken() == "session")
        print("AUTH_TIMING total=\(elapsed) awake=\(awake) outcome=timedOut requests=\(await fixture.count)")
        session.invalidateAndCancel()
        await fixture.close()
    }
}
