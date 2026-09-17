import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import StackAuth

@Suite(.serialized)
struct RateLimitRetryTests {
    @Test func rateLimitReturnsAfterOneProviderRequest() async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            baseUrl: "https://stack-auth.test",
            projectId: "project",
            publishableClientKey: "publishable",
            tokenStore: NullTokenStore(),
            session: session
        )

        do {
            _ = try await client.sendRequest(path: "/users/me")
            Issue.record("expected Stack Auth rate-limit error")
        } catch let error as any StackAuthErrorProtocol {
            #expect(error.code == "RATE_LIMITED")
        }

        #expect(RateLimitURLProtocol.requestCount == 1)
    }

    @Test func invalidAccessTokenRefreshIsBoundedToOneRetry() async throws {
        AuthRetryURLProtocol.reset(alwaysRejectRefreshedToken: true)
        let client = makeAuthRetryClient()
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "old-access", refreshToken: "refresh")

        do {
            _ = try await client.sendRequest(
                path: "/users/me",
                authenticated: true,
                tokenStoreOverride: store
            )
            Issue.record("expected invalid access token error")
        } catch let error as any StackAuthErrorProtocol {
            #expect(error.code == "invalid_access_token")
        }

        #expect(AuthRetryURLProtocol.requestCount == 3)
        #expect(AuthRetryURLProtocol.refreshCount == 1)
    }

    @Test func concurrentInvalidAccessTokensShareOneRefreshExchange() async throws {
        AuthRetryURLProtocol.reset(alwaysRejectRefreshedToken: false)
        let client = makeAuthRetryClient()
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "old-access", refreshToken: "refresh")

        let first = Task {
            await capture { try await client.sendRequest(
                path: "/users/me",
                authenticated: true,
                tokenStoreOverride: store
            ) }
        }
        let second = Task {
            await capture { try await client.sendRequest(
                path: "/users/me",
                authenticated: true,
                tokenStoreOverride: store
            ) }
        }
        let results = await [first.value, second.value]
        for result in results {
            if case let .failure(error) = result {
                Issue.record("unexpected concurrent auth retry error: \(error)")
            }
        }

        #expect(AuthRetryURLProtocol.refreshCount == 1)
        #expect(AuthRetryURLProtocol.requestCount == 5)
    }

    private func capture(
        _ operation: @escaping () async throws -> (Data, HTTPURLResponse)
    ) async -> Result<(Data, HTTPURLResponse), Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    private func makeAuthRetryClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthRetryURLProtocol.self]
        return APIClient(
            baseUrl: "https://stack-auth.test",
            projectId: "project",
            publishableClientKey: "publishable",
            tokenStore: NullTokenStore(),
            session: URLSession(configuration: configuration)
        )
    }
}

private final class RateLimitURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var count = 0

    static var requestCount: Int {
        lock.withLock { count }
    }

    static func reset() {
        lock.withLock { count = 0 }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["x-stack-known-error": "RATE_LIMITED"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(#"{"message":"slow down"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class AuthRetryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let newAccessToken =
        "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTksInN1YiI6InRlc3QifQ.signature"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var count = 0
    private nonisolated(unsafe) static var refreshes = 0
    private nonisolated(unsafe) static var rejectRefreshedToken = false

    static var requestCount: Int {
        lock.withLock { count }
    }

    static var refreshCount: Int {
        lock.withLock { refreshes }
    }

    static func reset(alwaysRejectRefreshedToken: Bool) {
        lock.withLock {
            count = 0
            refreshes = 0
            rejectRefreshedToken = alwaysRejectRefreshedToken
        }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var shouldRejectRefreshedToken = false
        Self.lock.withLock {
            Self.count += 1
            shouldRejectRefreshedToken = Self.rejectRefreshedToken
            if request.url?.path.hasSuffix("/auth/oauth/token") == true {
                Self.refreshes += 1
            }
        }

        let isRefresh = request.url?.path.hasSuffix("/auth/oauth/token") == true
        let token = request.value(forHTTPHeaderField: "x-stack-access-token")
        let statusCode = isRefresh ? 200 :
            (token == Self.newAccessToken && !shouldRejectRefreshedToken ? 200 : 401)
        let headers = statusCode == 200
            ? ["content-type": "application/json"]
            : [
                "x-stack-actual-status": "401",
                "x-stack-known-error": "invalid_access_token",
            ]
        let body = isRefresh
            ? Data(#"{"access_token":"eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTksInN1YiI6InRlc3QifQ.signature"}"#.utf8)
            : Data(#"{"message":"expired"}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
