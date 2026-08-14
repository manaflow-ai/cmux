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
