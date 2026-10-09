import CNBackend
import CNCore
import Foundation
import Synchronization
import Testing

/// URL stub that can set response headers (Retry-After).
final class HeaderStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)
    static let handler = Mutex<Handler?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let h = Self.handler.withLock { $0 }
        let (status, headers, body) = h?(request) ?? (500, [:], Data())
        var fields = headers
        fields["Content-Type"] = "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Manually advanced time for the ICE cache.
final class TestNow: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_000_000))
    var date: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

@Suite(.serialized) struct ICECacheTests {
    let user = User(id: "u_1", email: "a@test.cmux.dev", name: "A")
    let iceJSON = Data(#"{"iceServers":[{"urls":["turn:turn.example.test:3478"],"username":"u","credential":"c"}],"ttl":100}"#.utf8)

    func makeClient(now: TestNow) -> BackendClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeaderStubURLProtocol.self]
        let store = InMemoryTokenStore(StoredSession(accessToken: "a", refreshToken: "r", accessTokenExpiresAt: Date().addingTimeInterval(3600), user: user))
        return BackendClient(configuration: BackendConfiguration(baseURL: URL(string: "https://api.example.test")!),
                             tokenStore: store, urlSession: URLSession(configuration: config), now: { now.date })
    }

    @Test func cachesUntilEightyPercentOfTTL() async throws {
        let now = TestNow()
        let backend = makeClient(now: now)
        let calls = Mutex(0)
        HeaderStubURLProtocol.handler.withLock {
            $0 = { [iceJSON] _ in calls.withLock { $0 += 1 }; return (200, [:], iceJSON) }
        }
        _ = try await backend.iceConfiguration()
        _ = try await backend.iceConfiguration()
        now.advance(79)
        _ = try await backend.iceConfiguration()
        #expect(calls.withLock { $0 } == 1)
        now.advance(2)
        _ = try await backend.iceConfiguration()
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func concurrentCallsShareOneRequest() async throws {
        let backend = makeClient(now: TestNow())
        let calls = Mutex(0)
        HeaderStubURLProtocol.handler.withLock {
            $0 = { [iceJSON] _ in calls.withLock { $0 += 1 }; return (200, [:], iceJSON) }
        }
        async let a = backend.iceConfiguration()
        async let b = backend.iceConfiguration()
        async let c = backend.iceConfiguration()
        _ = try await (a, b, c)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func rateLimitUsesUnexpiredCacheThenHonorsRetryAfter() async throws {
        let now = TestNow()
        let backend = makeClient(now: now)
        let calls = Mutex(0)
        let limited = Mutex(false)
        HeaderStubURLProtocol.handler.withLock {
            $0 = { [iceJSON] _ in
                calls.withLock { $0 += 1 }
                if limited.withLock({ $0 }) { return (429, ["Retry-After": "40"], Data(#"{"error":{"code":"rate_limited","message":"slow"}}"#.utf8)) }
                return (200, [:], iceJSON)
            }
        }
        _ = try await backend.iceConfiguration()
        limited.withLock { $0 = true }
        now.advance(85) // past 80 % of ttl, still inside ttl
        let stale = try await backend.iceConfiguration() // 429: falls back to cached creds
        #expect(stale.ttl == 100)
        #expect(calls.withLock { $0 } == 2)
        // Inside Retry-After with unexpired creds: no request at all.
        now.advance(5)
        _ = try await backend.iceConfiguration()
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func rateLimitWithoutCacheFailsOnceWithoutRetrying() async throws {
        let backend = makeClient(now: TestNow())
        let calls = Mutex(0)
        HeaderStubURLProtocol.handler.withLock {
            $0 = { _ in calls.withLock { $0 += 1 }; return (429, ["Retry-After": "3"], Data()) }
        }
        await #expect(throws: BackendError.self) { try await backend.iceConfiguration() }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func appleNonceHashesRawValue() {
        let nonce = AppleSignInNonce(raw: "abc")
        #expect(nonce.hashed == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(AppleSignInNonce().raw.count >= 43)
    }
}
