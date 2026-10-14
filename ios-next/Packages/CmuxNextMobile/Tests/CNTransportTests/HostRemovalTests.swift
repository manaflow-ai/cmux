import CNBackend
import CNCore
import Foundation
import Testing

/// Fixed `/hosts` answer (own class: other suites' stubs run in parallel).
final class HostListStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Data(#"{"hosts":[{"id":"h_1","name":"A","os":"macOS","online":true,"lastSeenAt":1,"createdAt":1},{"id":"h_2","name":"B","os":"macOS","online":true,"lastSeenAt":1,"createdAt":1}]}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct HostRemovalTests {
    @Test func presenceDecodesRemoved() throws {
        let frame = Data(#"{"type":"presence","hostId":"h_1","online":false,"removed":true}"#.utf8)
        guard case .presence(let p) = try JSONDecoder().decode(SignalMessage.self, from: frame) else {
            Issue.record("not a presence frame"); return
        }
        #expect(p == HostPresence(hostId: "h_1", online: false, removed: true))
        let plain = Data(#"{"type":"presence","hostId":"h_2","online":true}"#.utf8)
        guard case .presence(let q) = try JSONDecoder().decode(SignalMessage.self, from: plain) else { return }
        #expect(q.removed == false)
        // Round trip keeps the flag.
        let again = try JSONDecoder().decode(SignalMessage.self, from: JSONEncoder().encode(SignalMessage.presence(p)))
        #expect(again == .presence(p))
    }

    @MainActor @Test func removedPresenceDropsTheHost() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HostListStubURLProtocol.self]
        let user = User(id: "u_1", email: "a@test.cmux.dev", name: "A")
        let store = InMemoryTokenStore(StoredSession(accessToken: "a", refreshToken: "r", accessTokenExpiresAt: Date().addingTimeInterval(3600), user: user))
        let backend = BackendClient(configuration: BackendConfiguration(baseURL: URL(string: "https://api.example.test")!),
                                    tokenStore: store, urlSession: URLSession(configuration: config))
        let hosts = HostsStore(backend: backend)
        await hosts.refresh()
        #expect(hosts.hosts.count == 2)
        hosts.apply(HostPresence(hostId: "h_1", online: false, removed: true))
        #expect(hosts.hosts.map(\.id) == ["h_2"])
        hosts.apply(HostPresence(hostId: "h_2", online: false))
        #expect(hosts.hosts.first?.online == false)
    }
}
