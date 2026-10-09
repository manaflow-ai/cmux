// DEVELOPMENT FIXTURE: an in-process stand-in for the PROTOCOL §5 backend so
// CMUX_NEXT_MOCK / CMUX_NEXT_DEV_SCREEN runs need no network or account.

import CNBackend
import CNCore
import CNMockHost
import Foundation
import Synchronization

/// Fixture backend state shared by every `MockBackendURLProtocol` request.
final class MockBackendState: Sendable {
    static let shared = MockBackendState()
    static let baseURL = URL(string: "https://mock.cmux-next.invalid")!
    static let user = User(id: "u_demo", email: "demo@cmux.dev", name: "Demo User")

    private struct State {
        var hosts: [HostRecord] = []
        var pairableHost: HostRecord?
    }

    private let state = Mutex(State())

    /// `hosts` are listed now; `pairable` is added when any code is approved.
    func configure(hosts: [HostRecord], pairable: HostRecord?) {
        state.withLock { $0 = State(hosts: hosts, pairableHost: pairable) }
    }

    func handle(method: String, path: String, body: Data?) -> (Int, Any) {
        switch (method, path) {
        case ("GET", "/v1/me"):
            return (200, ["user": Self.json(Self.user)])
        case ("DELETE", "/v1/me"), ("POST", "/v1/auth/logout"):
            return (200, [String: Any]())
        case ("POST", "/v1/auth/refresh"):
            return (200, Self.json(Self.tokens()))
        case ("GET", "/v1/hosts"):
            return (200, ["hosts": state.withLock { $0.hosts }.map(Self.json)])
        case ("POST", "/v1/hosts/pair/approve"):
            guard let host = state.withLock({ s -> HostRecord? in
                guard let h = s.pairableHost else { return nil }
                s.hosts.removeAll { $0.id == h.id }
                s.hosts.insert(h, at: 0)
                return h
            }) else {
                return (404, ["error": ["code": "not_found", "message": "That code is not valid or has expired."]])
            }
            return (200, ["host": Self.json(host)])
        case ("GET", "/v1/ice"):
            return (200, ["iceServers": [Any](), "ttl": 3600])
        default:
            if method == "DELETE", path.hasPrefix("/v1/hosts/") {
                let id = String(path.dropFirst("/v1/hosts/".count))
                state.withLock { $0.hosts.removeAll { $0.id == id } }
                return (200, [String: Any]())
            }
            return (404, ["error": ["code": "not_found", "message": "Mock backend: \(method) \(path)"]])
        }
    }

    static func tokens() -> Tokens {
        Tokens(accessToken: "mock-access", refreshToken: "mock-refresh", expiresIn: 86_400 * 365, user: user)
    }

    static func storedSession() -> StoredSession { StoredSession(tokens: tokens()) }

    private static func json<T: Encodable>(_ value: T) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) ?? [:]
    }
}

/// Answers backend requests from `MockBackendState`.
final class MockBackendURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == MockBackendState.baseURL.host()
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        let (status, object) = MockBackendState.shared.handle(method: request.httpMethod ?? "GET", path: url.path(), body: body)
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockBackendURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
