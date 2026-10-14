import CNBackend
import CNCore
import Foundation
import Synchronization
import Testing

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)
    static let handler = Mutex<Handler?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let h = Self.handler.withLock { $0 }
        let (status, body) = h?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct BackendClientTests {
    let user = User(id: "u_1", email: "a@test.cmux.dev", name: "A")

    func makeClient(store: InMemoryTokenStore) -> BackendClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return BackendClient(configuration: BackendConfiguration(baseURL: URL(string: "https://api.example.test/v1/")!),
                             tokenStore: store, urlSession: URLSession(configuration: config))
    }

    func tokensJSON(_ access: String) -> Data {
        Data(#"{"accessToken":"\#(access)","refreshToken":"r2","expiresIn":900,"user":{"id":"u_1","email":"a@test.cmux.dev","name":"A"}}"#.utf8)
    }

    @Test func configurationResolvesPaths() {
        let c = BackendConfiguration(bundle: .main, environment: ["CMUX_NEXT_API_BASE": "https://w.example.dev"])
        #expect(c?.url("/hosts").absoluteString == "https://w.example.dev/v1/hosts")
        #expect(c?.signalingURL(token: "t").absoluteString == "wss://w.example.dev/v1/signal?token=t")
    }

    @Test func refreshOn401IsSingleFlight() async throws {
        let store = InMemoryTokenStore(StoredSession(accessToken: "old", refreshToken: "r1", accessTokenExpiresAt: Date().addingTimeInterval(600), user: user))
        let backend = makeClient(store: store)
        let refreshes = Mutex(0)
        StubURLProtocol.handler.withLock {
            $0 = { [tokensJSON] req in
                switch req.url!.path {
                case "/v1/auth/refresh":
                    refreshes.withLock { $0 += 1 }
                    return (200, tokensJSON("new"))
                case "/v1/hosts":
                    guard req.value(forHTTPHeaderField: "Authorization") == "Bearer new" else {
                        return (401, Data(#"{"error":{"code":"unauthorized","message":"expired"}}"#.utf8))
                    }
                    return (200, Data(#"{"hosts":[{"id":"h_1","name":"Mac","os":"macOS","online":true,"lastSeenAt":1,"createdAt":1}]}"#.utf8))
                default:
                    return (404, Data())
                }
            }
        }
        let results = try await withThrowingTaskGroup(of: [HostRecord].self) { group in
            for _ in 0..<6 { group.addTask { try await backend.hosts() } }
            var all: [[HostRecord]] = []
            for try await r in group { all.append(r) }
            return all
        }
        #expect(results.count == 6 && results.allSatisfy { $0.first?.id == "h_1" })
        #expect(refreshes.withLock { $0 } == 1)
        #expect(store.load()?.accessToken == "new")
        #expect(store.load()?.refreshToken == "r2")
    }

    @Test func rejectedRefreshSignsOut() async throws {
        let store = InMemoryTokenStore(StoredSession(accessToken: "old", refreshToken: "bad", accessTokenExpiresAt: Date().addingTimeInterval(600), user: user))
        let backend = makeClient(store: store)
        StubURLProtocol.handler.withLock {
            $0 = { _ in (401, Data(#"{"error":{"code":"unauthorized","message":"nope"}}"#.utf8)) }
        }
        let events = await backend.sessionEvents()
        await #expect(throws: BackendError.self) { try await backend.me() }
        #expect(store.load() == nil)
        var it = events.makeAsyncIterator()
        #expect(await it.next() == .signedOut)
    }

    @Test func emailSignInStoresTokens() async throws {
        let store = InMemoryTokenStore()
        let backend = makeClient(store: store)
        StubURLProtocol.handler.withLock {
            $0 = { [tokensJSON] req in
                switch req.url!.path {
                case "/v1/auth/email/start": (200, Data(#"{"nonce":"n1"}"#.utf8))
                case "/v1/auth/email/verify": (200, tokensJSON("acc"))
                default: (404, Data())
                }
            }
        }
        let nonce = try await backend.startEmail("a@test.cmux.dev")
        let u = try await backend.verifyEmail(email: "a@test.cmux.dev", code: "ABC123", nonce: nonce)
        #expect(u.id == "u_1" && store.load()?.accessToken == "acc")
    }
}
