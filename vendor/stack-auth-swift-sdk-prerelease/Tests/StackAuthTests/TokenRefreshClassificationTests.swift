import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StackAuth

// MARK: - Stub transport

/// A `URLProtocol` that answers the OAuth token-refresh request with a scripted
/// outcome, so the refresh-token classification can be exercised against
/// synthetic HTTP statuses and transport errors without a live server.
///
/// The desired outcome is encoded in a request header (`X-Test-Refresh-Outcome`)
/// rather than shared mutable state, so concurrent test cases never race on a
/// global. Recognized values:
/// - `success`: HTTP 200 with a parseable `{"access_token": ...}` body.
/// - `status:<code>`: an HTTP response with the given status and an empty body
///   (e.g. `status:401`, `status:503`).
/// - `urlerror`: a `URLError(.notConnectedToInternet)`, i.e. an offline blip.
private final class RefreshStubURLProtocol: URLProtocol {
    static let outcomeHeader = "X-Test-Refresh-Outcome"

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: outcomeHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let outcome = request.value(forHTTPHeaderField: Self.outcomeHeader) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        if outcome == "urlerror" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let statusCode: Int
        let body: Data
        if outcome == "success" {
            statusCode = 200
            body = Data(#"{"access_token":"fresh.access.token","refresh_token":"r"}"#.utf8)
        } else if outcome.hasPrefix("status:"), let code = Int(outcome.dropFirst("status:".count)) {
            statusCode = code
            body = Data()
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

/// Regression coverage for the transient-vs-definitive signout fix.
///
/// Root cause (proven by a live experiment): a TRANSIENT refresh failure
/// (offline, timeout, 5xx, malformed body) used to wipe a still-valid refresh
/// token, silently signing the user out forever — "connection lost / retry
/// fails forever" even though the same refresh token still worked moments later.
/// The fix classifies the refresh outcome and only clears tokens on a DEFINITIVE
/// rejection (HTTP 400/401 from the token endpoint).
///
/// These tests assert that load-bearing rule at the exact layer the bug lived in
/// — the SDK's `APIClient.fetchNewAccessToken` → `refresh` → store mutation — by
/// driving real `URLSession` traffic through a stub `URLProtocol` and inspecting
/// the token store afterward. The coordinator layer
/// (`AuthCoordinatorSessionValidityTests` in `CmuxAuthRuntime`) is already
/// covered separately at the token-presence level; this fills the HTTP-status
/// classification gap.
@Suite("Token Refresh Classification (transient vs definitive signout)")
struct TokenRefreshClassificationTests {
    /// Build an `APIClient` whose transport is a stub `URLProtocol` and seed a
    /// known refresh + access token in a fresh isolated `MemoryTokenStore`.
    private func makeClient(
        outcome: String,
        store: MemoryTokenStore
    ) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshStubURLProtocol.self]
        // Carry the scripted outcome on every request issued through this session
        // so the stub answers deterministically without shared mutable state.
        configuration.httpAdditionalHeaders = [RefreshStubURLProtocol.outcomeHeader: outcome]
        let session = URLSession(configuration: configuration)
        return APIClient(
            baseUrl: "https://stub.invalid",
            projectId: "test-project",
            publishableClientKey: "test-key",
            tokenStore: store,
            session: session
        )
    }

    /// Build a syntactically valid JWT access token whose `exp` is in the past,
    /// so `isTokenFreshEnough` is false and the normal `getAccessToken` path
    /// actually attempts a refresh (instead of short-circuiting on a fresh
    /// cached token). The body is irrelevant to the server; only the JWT shape
    /// and expiry matter to the SDK's local freshness check.
    private func expiredAccessTokenJWT() -> String {
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" // {"alg":"HS256","typ":"JWT"}
        let now = Int(Date().timeIntervalSince1970)
        let payloadJSON = "{\"exp\":\(now - 3600),\"iat\":\(now - 7200),\"sub\":\"test\"}"
        let payload = Data(payloadJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(payload).signature"
    }

    /// A DEFINITIVE rejection (HTTP 401 from the token endpoint) clears both
    /// tokens: the refresh token genuinely no longer works, so the user must
    /// re-authenticate.
    @Test("HTTP 401 definitively clears the refresh token")
    func definitiveRejectionClearsTokens() async {
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "stale.access", refreshToken: "valid-refresh")
        let client = makeClient(outcome: "status:401", store: store)

        let pair = await client.fetchNewAccessToken()

        #expect(pair.accessToken == nil)
        #expect(pair.refreshToken == nil)
        // The store itself must be wiped, not just the returned pair.
        #expect(await store.getStoredRefreshToken() == nil)
        #expect(await store.getStoredAccessToken() == nil)
    }

    /// HTTP 400 (`invalid_grant`) is also definitive and clears the token.
    @Test("HTTP 400 definitively clears the refresh token")
    func badRequestClearsTokens() async {
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "stale.access", refreshToken: "valid-refresh")
        let client = makeClient(outcome: "status:400", store: store)

        _ = await client.fetchNewAccessToken()

        #expect(await store.getStoredRefreshToken() == nil)
        #expect(await store.getStoredAccessToken() == nil)
    }

    /// A TRANSIENT 5xx (server hiccup) must PRESERVE the refresh token. This is
    /// the regression: pre-fix, this path wiped a still-valid token and signed
    /// the user out forever.
    @Test("HTTP 503 preserves the refresh token (transient, retryable)")
    func transientServerErrorPreservesRefreshToken() async {
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "stale.access", refreshToken: "valid-refresh")
        let client = makeClient(outcome: "status:503", store: store)

        let pair = await client.fetchNewAccessToken()

        // No new access token was minted, but the session is intact and retryable.
        #expect(pair.accessToken == nil)
        #expect(pair.refreshToken == "valid-refresh")
        #expect(await store.getStoredRefreshToken() == "valid-refresh")
    }

    /// A TRANSIENT transport failure (offline / `URLError`) must also PRESERVE
    /// the refresh token. A momentary network blip is never the token's fault.
    @Test("URLError (offline) preserves the refresh token (transient, retryable)")
    func transientNetworkErrorPreservesRefreshToken() async {
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "stale.access", refreshToken: "valid-refresh")
        let client = makeClient(outcome: "urlerror", store: store)

        let pair = await client.fetchNewAccessToken()

        #expect(pair.refreshToken == "valid-refresh")
        #expect(await store.getStoredRefreshToken() == "valid-refresh")
    }

    /// The happy path: a successful refresh mints a new access token and keeps
    /// the refresh token, proving the stub transport and seam are wired
    /// correctly (so the preserve/clear assertions above are meaningful).
    @Test("HTTP 200 mints a new access token and keeps the refresh token")
    func successfulRefreshUpdatesAccessToken() async {
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "stale.access", refreshToken: "valid-refresh")
        let client = makeClient(outcome: "success", store: store)

        let pair = await client.fetchNewAccessToken()

        #expect(pair.accessToken == "fresh.access.token")
        #expect(pair.refreshToken == "valid-refresh")
        #expect(await store.getStoredAccessToken() == "fresh.access.token")
        #expect(await store.getStoredRefreshToken() == "valid-refresh")
    }

    // MARK: - Normal getAccessToken path (getOrFetchLikelyValidTokens)

    // The live "every retry fails forever" repro loops through `getAccessToken`
    // (→ `getOrFetchLikelyValidTokensFromStore`), not the post-401 force-refresh
    // path above. These cases drive that primary path with a stored access token
    // that is expired (so the SDK refreshes rather than returning the cached one)
    // and assert the same transient-preserve / definitive-clear contract.

    /// A TRANSIENT 5xx on the normal `getAccessToken` path PRESERVES the refresh
    /// token so the next retry (after the network recovers) succeeds. This is the
    /// exact branch the permanent-signout repro looped through.
    @Test("getAccessToken: HTTP 503 preserves the refresh token (transient)")
    func getAccessTokenTransientServerErrorPreservesRefreshToken() async {
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: expiredAccessTokenJWT(), refreshToken: "valid-refresh")
        let client = makeClient(outcome: "status:503", store: store)

        let token = await client.getAccessToken()

        // No usable access token right now, but the session survives and retries.
        #expect(token == nil)
        #expect(await store.getStoredRefreshToken() == "valid-refresh")
    }

    /// A TRANSIENT transport failure (offline) on the normal path also PRESERVES
    /// the refresh token.
    @Test("getAccessToken: URLError (offline) preserves the refresh token (transient)")
    func getAccessTokenTransientNetworkErrorPreservesRefreshToken() async {
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: expiredAccessTokenJWT(), refreshToken: "valid-refresh")
        let client = makeClient(outcome: "urlerror", store: store)

        _ = await client.getAccessToken()

        #expect(await store.getStoredRefreshToken() == "valid-refresh")
    }

    /// A DEFINITIVE 401 on the normal path clears both tokens.
    @Test("getAccessToken: HTTP 401 definitively clears the refresh token")
    func getAccessTokenDefinitiveRejectionClearsTokens() async {
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: expiredAccessTokenJWT(), refreshToken: "valid-refresh")
        let client = makeClient(outcome: "status:401", store: store)

        let token = await client.getAccessToken()

        #expect(token == nil)
        #expect(await store.getStoredRefreshToken() == nil)
        #expect(await store.getStoredAccessToken() == nil)
    }

    /// Happy path on the normal accessor: a successful refresh mints and stores a
    /// new access token while keeping the refresh token.
    @Test("getAccessToken: HTTP 200 mints and stores a new access token")
    func getAccessTokenSuccessfulRefreshUpdatesAccessToken() async {
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: expiredAccessTokenJWT(), refreshToken: "valid-refresh")
        let client = makeClient(outcome: "success", store: store)

        let token = await client.getAccessToken()

        #expect(token == "fresh.access.token")
        #expect(await store.getStoredAccessToken() == "fresh.access.token")
        #expect(await store.getStoredRefreshToken() == "valid-refresh")
    }
}
