import Foundation
import Testing
@testable import StackAuth

@Suite struct RefreshLifecycleTests {
    static let fresh = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTl9.synthetic"

    @Test func freshStoredTokensDoNotStartARefresh() async {
        let fixture = RefreshTransportFixture()
        let session = await fixture.session()
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: Self.fresh, refreshToken: "session")
        await fixture.release(status: 503, token: "unused")
        let client = APIClient(baseUrl: "https://" + fixture.host, projectId: "fixture", publishableClientKey: "synthetic", tokenStore: store, session: session)
        let pair = await client.getOrFetchLikelyValidTokens()
        #expect(pair.accessToken == Self.fresh)
        #expect(pair.refreshToken == "session")
        #expect(await fixture.count == 0)
        session.invalidateAndCancel()
        await fixture.close()
    }

    @Test func concurrentFailureIsSharedAndCancelledWaitersDetach() async {
        let fixture = RefreshTransportFixture()
        let session = await fixture.session()
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "expired", refreshToken: "session-a")
        let client = APIClient(baseUrl: "https://" + fixture.host, projectId: "fixture", publishableClientKey: "synthetic", tokenStore: store, session: session)
        let completion = RefreshFixtureCompletion()
        let calls = (0..<4).map { index in Task {
            let result = await client.getOrFetchLikelyValidTokens()
            if index < 2 { await completion.finish() }
            return result
        } }
        await fixture.waitForRequest()
        calls[0].cancel()
        calls[1].cancel()
        let detached = await completion.withinDeadline()
        #expect(detached, "Cancelling two auth callers must detach them before transport completes")
        await fixture.release(status: 503, token: "unused")
        for call in calls { #expect(await call.value.accessToken == nil) }
        #expect(await fixture.count == 1, "Concurrent failed refresh callers must share one exchange")
        #expect(await store.getStoredRefreshToken() == "session-a")
        session.invalidateAndCancel()
        await fixture.close()
    }

    @Test func lateRefreshNeverReturnsSignedOutCredentials() async {
        let fixture = RefreshTransportFixture()
        let session = await fixture.session()
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "expired", refreshToken: "session-a")
        let client = APIClient(baseUrl: "https://" + fixture.host, projectId: "fixture", publishableClientKey: "synthetic", tokenStore: store, session: session)
        let request = Task { await client.getOrFetchLikelyValidTokens() }
        await fixture.waitForRequest()
        await client.clearTokens()
        await fixture.release(token: Self.fresh)
        let pair = await request.value
        #expect(pair.accessToken == nil, "A late refresh must not return credentials after sign-out")
        #expect(await store.getStoredAccessToken() == nil)
        #expect(await store.getStoredRefreshToken() == nil)
        session.invalidateAndCancel()
        await fixture.close()
    }

    @Test func lateRefreshNeverReturnsPreviousAccountCredentials() async {
        let fixture = RefreshTransportFixture()
        let session = await fixture.session()
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "expired", refreshToken: "session-a")
        let client = APIClient(baseUrl: "https://" + fixture.host, projectId: "fixture", publishableClientKey: "synthetic", tokenStore: store, session: session)
        let request = Task { await client.getOrFetchLikelyValidTokens() }
        await fixture.waitForRequest()
        await client.setTokens(accessToken: "account-b", refreshToken: "session-b")
        await fixture.release(token: Self.fresh)
        let pair = await request.value
        #expect(pair.accessToken == nil, "Account replacement must reject the old in-flight capture")
        #expect(await store.getStoredAccessToken() == "account-b")
        #expect(await store.getStoredRefreshToken() == "session-b")
        session.invalidateAndCancel()
        await fixture.close()
    }

    @Test func accessOnlySessionReplacementIsRejected() async {
        let store = TokenOnlyRaceStore(access: Self.fresh)
        let client = APIClient(
            baseUrl: "https://fixture.invalid",
            projectId: "fixture",
            publishableClientKey: "synthetic",
            tokenStore: store
        )

        let pair = await client.getOrFetchLikelyValidTokens()

        #expect(pair.accessToken == nil)
        #expect(pair.refreshFailure == .sessionChanged)
        #expect(await store.getStoredAccessToken() == "replacement")
    }
}

private actor TokenOnlyRaceStore: TokenStoreProtocol {
    private var accessToken: String?
    private var accessReads = 0

    init(access: String) {
        accessToken = access
    }

    func getStoredAccessToken() async -> String? {
        let captured = accessToken
        accessReads += 1
        if accessReads == 1 {
            accessToken = "replacement"
        }
        return captured
    }

    func getStoredRefreshToken() async -> String? { nil }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        self.accessToken = accessToken
    }

    func clearTokens() async {
        accessToken = nil
    }

    func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        accessToken = newAccessToken
    }
}
