import Foundation
import Testing
@testable import StackAuth

// swift-corelibs-foundation traps in TaskRegistry when the timed-out task's
// connection is torn down after the client gives up, so this real-transport
// smoke runs on Apple platforms only.
@Suite(.disabled(if: TestConfig.isLinux, "corelibs URLSession traps on the late teardown"))
struct RefreshTransportTimingTests {
    // Deliberate runtime timing smoke for the incident proof. Virtual deadline
    // and wake ordering are covered separately by RefreshDeadlineTests.
    @Test func realTransportWaitHasATotalDeadline() async {
        let fixture = RefreshTransportFixture()
        let session = await fixture.session()
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "expired", refreshToken: "session")
        let client = APIClient(baseUrl: "https://" + fixture.host, projectId: "fixture", publishableClientKey: "synthetic", tokenStore: store, session: session,
            refreshTimeoutNanoseconds: 100_000_000)
        let start = ContinuousClock.now
        let active = SuspendingClock.now
        let request = Task { await client.getOrFetchLikelyValidTokens() }
        await fixture.waitForRequest()
        print("AUTH_TRANSPORT_PARKED pid=\(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)
        let result = await request.value
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
