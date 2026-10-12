import Foundation
public import CmuxNativeWire

/// REST client for the `cmux-next-native` Worker.
public struct WorkerAPI: Sendable {
    public struct Failure: Error, Equatable, Sendable, CustomStringConvertible {
        public var status: Int
        public var code: String
        public var message: String?
        public var description: String { "HTTP \(status) \(code)\(message.map { ": \($0)" } ?? "")" }
    }

    public var baseURL: URL
    /// Session token (phone) or host secret (host).
    public var token: String?
    private let session: URLSession

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func withToken(_ token: String?) -> WorkerAPI {
        var copy = self
        copy.token = token
        return copy
    }

    // MARK: Endpoints

    public func authApple(_ body: AppleAuthRequest) async throws -> AuthResponse {
        try await call("POST", "/v1/auth/apple", body: body)
    }

    public func authDev(email: String, secret: String) async throws -> AuthResponse {
        try await call("POST", "/v1/auth/dev", body: DevAuthRequest(email: email, secret: secret))
    }

    public func me() async throws -> MeResponse { try await call("GET", "/v1/me") }

    public func registerHost(name: String, platform: String) async throws -> HostRegisterResponse {
        try await call("POST", "/v1/hosts/register", body: HostRegisterRequest(name: name, platform: platform))
    }

    /// Host auth: rotates the pairing code.
    public func pairingCode() async throws -> PairingCodeResponse {
        try await call("POST", "/v1/hosts/pairing-code", body: [String: String]())
    }

    public func pair(code: String) async throws -> PairResponse {
        try await call("POST", "/v1/pair", body: PairRequest(code: code))
    }

    public func hosts() async throws -> HostsResponse { try await call("GET", "/v1/hosts") }

    public func unpair(hostID: String) async throws -> OKResponse { try await call("DELETE", "/v1/hosts/\(hostID)") }

    public func iceServers() async throws -> IceServersResponse { try await call("GET", "/v1/ice") }

    public func registerPush(_ body: PushRegisterRequest) async throws -> OKResponse {
        try await call("POST", "/v1/push/register", body: body)
    }

    /// `wss://…/v1/signal/<host_id>`.
    public func signalURL(hostID: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path)
            + "/v1/signal/\(hostID)"
        return components.url!
    }

    // MARK: Transport

    private func call<Response: Decodable>(_ method: String, _ path: String) async throws -> Response {
        try await perform(method, path, body: nil)
    }

    private func call<Response: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body) async throws -> Response {
        try await perform(method, path, body: try JSONEncoder().encode(body))
    }

    private func perform<Response: Decodable>(_ method: String, _ path: String, body: Data?) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = try? JSONDecoder().decode(WorkerErrorBody.self, from: data)
            throw Failure(status: status, code: detail?.error.code ?? "http_\(status)", message: detail?.error.message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
