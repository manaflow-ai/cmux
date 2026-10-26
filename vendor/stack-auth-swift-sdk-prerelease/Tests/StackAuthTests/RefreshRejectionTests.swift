import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import StackAuth

/// Answers every request to its synthetic host with one scripted response.
private final class ScriptedTokenEndpoint: URLProtocol, @unchecked Sendable {
    struct Answer: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Answer] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func requestCount(host: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[host] ?? 0
    }

    static func script(_ answer: Answer, host: String) {
        lock.lock(); answers[host] = answer; lock.unlock()
    }

    static func remove(host: String) {
        lock.lock(); answers[host] = nil; counts[host] = nil; lock.unlock()
    }

    private static func answer(host: String?) -> Answer? {
        lock.lock(); defer { lock.unlock() }
        return host.flatMap { answers[$0] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        answer(host: request.url?.host) != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let host = request.url?.host {
            Self.lock.lock(); Self.counts[host, default: 0] += 1; Self.lock.unlock()
        }
        guard let answer = Self.answer(host: request.url?.host),
              let response = HTTPURLResponse(
                  url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: answer.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// https://github.com/manaflow-ai/cmux/issues/25628: the token endpoint
/// answers 400/401 both for a dead refresh token and for a rejected client.
/// Only the first may clear the stored session.
@Suite struct RefreshRejectionTests {
    private static let expiredAccessToken: String = {
        let now = Int(Date().timeIntervalSince1970)
        let claims = Data("{\"iat\":\(now - 7200),\"exp\":\(now - 3600)}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(claims).synthetic"
    }()

    /// Runs `refreshes` refreshes against `answer` and returns the refresh
    /// token the store still holds afterwards, and how many exchanges reached
    /// the server.
    private func refresh(
        answering answer: ScriptedTokenEndpoint.Answer,
        refreshes: Int = 1
    ) async -> (refreshToken: String?, exchanges: Int) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        ScriptedTokenEndpoint.script(answer, host: host)
        defer { ScriptedTokenEndpoint.remove(host: host) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedTokenEndpoint.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let clock = RefreshTestClock()
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: Self.expiredAccessToken, refreshToken: "session")
        let client = APIClient(
            baseUrl: "https://" + host, projectId: "fixture", publishableClientKey: "synthetic",
            tokenStore: store, session: session, refreshClock: testClock(clock)
        )
        for _ in 0..<refreshes {
            _ = await client.getOrFetchLikelyValidTokens()
        }
        return (await store.getStoredRefreshToken(), ScriptedTokenEndpoint.requestCount(host: host))
    }

    private func refreshTokenAfterRefresh(answering answer: ScriptedTokenEndpoint.Answer) async -> String? {
        await refresh(answering: answer).refreshToken
    }

    @Test func rejectedPublishableKeyKeepsTheSession() async {
        let kept = await refreshTokenAfterRefresh(answering: .init(
            status: 401,
            headers: ["x-hexclave-known-error": "INVALID_PUBLISHABLE_CLIENT_KEY"],
            body: #"{"code":"INVALID_PUBLISHABLE_CLIENT_KEY","error":"The publishable key is not valid."}"#
        ))
        #expect(kept == "session")
    }

    @Test func rejectedOAuthClientKeepsTheSession() async {
        let kept = await refreshTokenAfterRefresh(answering: .init(
            status: 400,
            body: #"{"code":"INVALID_OAUTH_CLIENT_ID_OR_SECRET","error":"The OAuth client ID or secret is invalid."}"#
        ))
        #expect(kept == "session")
    }

    @Test func requiredPublishableKeyKeepsTheSession() async {
        let kept = await refreshTokenAfterRefresh(answering: .init(
            status: 401,
            headers: ["x-stack-known-error": "PUBLISHABLE_CLIENT_KEY_REQUIRED_FOR_PROJECT"],
            body: #"{"code":"PUBLISHABLE_CLIENT_KEY_REQUIRED_FOR_PROJECT","error":"Keys are required."}"#
        ))
        #expect(kept == "session")
    }

    @Test func rawOAuthClientErrorKeepsTheSession() async {
        let kept = await refreshTokenAfterRefresh(answering: .init(
            status: 400, body: #"{"error":"invalid_request","error_description":"Missing parameter"}"#
        ))
        #expect(kept == "session")
    }

    @Test func nonStackPageKeepsTheSession() async {
        let kept = await refreshTokenAfterRefresh(answering: .init(
            status: 401,
            headers: ["Content-Type": "text/html"],
            body: "<html><body>Sign in to the network</body></html>"
        ))
        #expect(kept == "session")
    }

    @Test func rejectedRequestIsNotRetriedDuringCooldown() async {
        let result = await refresh(answering: .init(
            status: 401,
            headers: ["x-hexclave-known-error": "INVALID_PUBLISHABLE_CLIENT_KEY"],
            body: #"{"code":"INVALID_PUBLISHABLE_CLIENT_KEY","error":"The publishable key is not valid."}"#
        ), refreshes: 3)
        #expect(result.refreshToken == "session")
        #expect(result.exchanges == 1)
    }

    @Test func newSessionClearsRejectedRequestCooldown() async {
        let host = UUID().uuidString.lowercased() + ".invalid"
        ScriptedTokenEndpoint.script(.init(
            status: 401,
            headers: ["x-hexclave-known-error": "INVALID_PUBLISHABLE_CLIENT_KEY"],
            body: #"{"code":"INVALID_PUBLISHABLE_CLIENT_KEY"}"#
        ), host: host)
        defer { ScriptedTokenEndpoint.remove(host: host) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedTokenEndpoint.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let clock = RefreshTestClock()
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: Self.expiredAccessToken, refreshToken: "old-session")
        let client = APIClient(
            baseUrl: "https://" + host, projectId: "fixture", publishableClientKey: "synthetic",
            tokenStore: store, session: session, refreshClock: testClock(clock)
        )

        _ = await client.getOrFetchLikelyValidTokens()
        await client.setTokens(accessToken: Self.expiredAccessToken, refreshToken: "new-session")
        ScriptedTokenEndpoint.script(.init(
            status: 200,
            body: #"{"access_token":"eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTl9.synthetic"}"#
        ), host: host)

        let result = await client.getOrFetchLikelyValidTokens()
        #expect(result.accessToken == RefreshLifecycleTests.fresh)
        #expect(result.refreshToken == "new-session")
        #expect(ScriptedTokenEndpoint.requestCount(host: host) == 2)
    }

    @Test func expiredRefreshTokenClearsTheSession() async {
        let kept = await refreshTokenAfterRefresh(answering: .init(
            status: 401,
            headers: ["x-hexclave-known-error": "REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED"],
            body: #"{"code":"REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED","error":"Refresh token not found."}"#
        ))
        #expect(kept == nil)
    }

    @Test func invalidGrantClearsTheSession() async {
        let kept = await refreshTokenAfterRefresh(answering: .init(
            status: 400, body: #"{"error":"invalid_grant"}"#
        ))
        #expect(kept == nil)
    }

    @Test func unnamedRejectionStillClearsTheSession() async {
        let kept = await refreshTokenAfterRefresh(answering: .init(status: 401, body: ""))
        #expect(kept == nil)
    }

    private func testClock(_ clock: RefreshTestClock) -> TokenRefreshClock {
        TokenRefreshClock(now: {
            let parts = clock.now.offset.components
            return UInt64(parts.seconds) * 1_000_000_000
                + UInt64(parts.attoseconds / 1_000_000_000)
        }, sleepUntil: {
            try await clock.sleep(until: .init(offset: .nanoseconds(Int64($0))), tolerance: nil)
        })
    }
}
