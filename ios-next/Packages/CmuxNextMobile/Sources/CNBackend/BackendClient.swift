import CNCore
import CryptoKit
import Foundation

/// Where the backend lives.
public struct BackendConfiguration: Sendable, Hashable {
    /// Worker origin, for example `https://cmux-next-mobile.example.workers.dev`.
    /// A trailing `/v1` is accepted and normalized away.
    public var baseURL: URL

    public init(baseURL: URL) {
        var s = baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1") { s.removeLast(3) }
        self.baseURL = URL(string: s) ?? baseURL
    }

    public static let infoPlistKey = "CmuxNextAPIBase"
    public static let environmentKey = "CMUX_NEXT_API_BASE"

    /// `CMUX_NEXT_API_BASE` from the environment, else `CmuxNextAPIBase` from
    /// Info.plist.
    public init?(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let raw = environment[Self.environmentKey].flatMap { $0.isEmpty ? nil : $0 }
            ?? (bundle.object(forInfoDictionaryKey: Self.infoPlistKey) as? String)
        guard let raw, !raw.isEmpty, !raw.hasPrefix("$("), let url = URL(string: raw) else { return nil }
        self.init(baseURL: url)
    }

    /// `<base>/v1<path>`
    public func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + "/v1" + path
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    /// The signaling WebSocket URL for `token`.
    public func signalingURL(token: String?) -> URL {
        var c = URLComponents(url: url("/signal"), resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        if let token { c.queryItems = [URLQueryItem(name: "token", value: token)] }
        return c.url!
    }
}

public enum BackendError: Error, Sendable, Hashable, LocalizedError {
    /// HTTP error with the backend's `{error:{code,message}}` body.
    case server(status: Int, code: String, message: String)
    case notSignedIn
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .server(_, _, let message): message
        case .notSignedIn: "You are signed out."
        case .invalidResponse(let m): "Unexpected response from the server: \(m)"
        }
    }

    public var status: Int? { if case .server(let s, _, _) = self { s } else { nil } }
}

public enum BackendSessionEvent: Sendable, Hashable {
    case signedIn(User)
    /// Tokens were cleared (sign out, account deletion, or refresh rejected).
    case signedOut
}

/// PROTOCOL §5 client. Attaches the access token, refreshes it on 401 (one
/// refresh at a time), and persists the session in a `TokenStore`.
public actor BackendClient {
    public nonisolated let configuration: BackendConfiguration
    public nonisolated let tokenStore: any TokenStore
    private let urlSession: URLSession
    private var session: StoredSession?
    private var refreshTask: Task<StoredSession, any Error>?
    private var eventContinuations: [UUID: AsyncStream<BackendSessionEvent>.Continuation] = [:]
    /// Refresh this long before the access token expires.
    public nonisolated let refreshLeeway: TimeInterval = 60

    public init(configuration: BackendConfiguration, tokenStore: any TokenStore, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.urlSession = urlSession
        self.session = tokenStore.load()
    }

    public var currentSession: StoredSession? { session }

    public func sessionEvents() -> AsyncStream<BackendSessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: BackendSessionEvent.self)
        let id = UUID()
        eventContinuations[id] = continuation
        continuation.onTermination = { _ in Task { await self.removeContinuation(id) } }
        return stream
    }

    private func removeContinuation(_ id: UUID) { eventContinuations[id] = nil }

    private func emit(_ e: BackendSessionEvent) { for c in eventContinuations.values { c.yield(e) } }

    // MARK: Auth

    /// Mails a code; returns the nonce for `verifyEmail`.
    public func startEmail(_ email: String) async throws -> String {
        struct R: Decodable { var nonce: String }
        return try await send("POST", "/auth/email/start", body: ["email": email], auth: false, as: R.self).nonce
    }

    @discardableResult
    public func verifyEmail(email: String, code: String, nonce: String) async throws -> User {
        try await adopt(send("POST", "/auth/email/verify", body: ["email": email, "code": code, "nonce": nonce], auth: false, as: Tokens.self))
    }

    @discardableResult
    public func signInWithApple(identityToken: String, fullName: String? = nil) async throws -> User {
        var body = ["identityToken": identityToken]
        if let fullName, !fullName.isEmpty { body["fullName"] = fullName }
        return try await adopt(send("POST", "/auth/apple", body: body, auth: false, as: Tokens.self))
    }

    /// The URL that starts an OAuth flow for `provider` (`github`, `google`).
    /// With `pkce`, the S256 `code_challenge` is sent and the backend binds
    /// the one-time code to it.
    public nonisolated func oauthStartURL(provider: String, redirect: String, pkce: PKCE? = nil) -> URL {
        var query = [URLQueryItem(name: "redirect", value: redirect)]
        if let pkce {
            query.append(URLQueryItem(name: "code_challenge", value: pkce.challenge))
            query.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        return configuration.url("/auth/oauth/\(provider)/start", query: query)
    }

    @discardableResult
    public func exchangeOAuth(code: String, codeVerifier: String? = nil) async throws -> User {
        var body = ["code": code]
        if let codeVerifier { body["codeVerifier"] = codeVerifier }
        return try await adopt(send("POST", "/auth/oauth/exchange", body: body, auth: false, as: Tokens.self))
    }

    /// Primary sign-in: exchanges a Stack Auth access token (the same
    /// accounts as cmux iOS) for a backend session (`POST /v1/auth/stack`).
    @discardableResult
    public func signInWithStack(accessToken: String, projectId: String) async throws -> User {
        try await adopt(send("POST", "/auth/stack", body: ["accessToken": accessToken, "projectId": projectId], auth: false, as: Tokens.self))
    }

    /// Automated-verification login (`POST /v1/auth/test {email, secret}`).
    @discardableResult
    public func testLogin(email: String, secret: String) async throws -> User {
        try await adopt(send("POST", "/auth/test", body: ["email": email, "secret": secret], auth: false, as: Tokens.self))
    }

    /// Revokes the refresh token (best effort) and clears local tokens.
    public func signOut() async {
        if let refreshToken = session?.refreshToken {
            _ = try? await send("POST", "/auth/logout", body: ["refreshToken": refreshToken], auth: true, as: EmptyPayload.self)
        }
        clearSession()
    }

    public func me() async throws -> User {
        struct R: Decodable { var user: User }
        let user = try await send("GET", "/me", auth: true, as: R.self).user
        if var s = session, s.user != user {
            s.user = user
            session = s
            try? tokenStore.save(s)
        }
        return user
    }

    public func deleteAccount() async throws {
        _ = try await send("DELETE", "/me", auth: true, as: EmptyPayload.self)
        clearSession()
    }

    // MARK: Hosts

    public func pairStart(name: String, os: String) async throws -> PairStartResult {
        try await send("POST", "/hosts/pair/start", body: ["name": name, "os": os], auth: false, as: PairStartResult.self)
    }

    public func pairPoll(deviceCode: String) async throws -> PairPollResult {
        try await send("POST", "/hosts/pair/poll", body: ["deviceCode": deviceCode], auth: false, as: PairPollResult.self)
    }

    public func approvePairing(userCode: String) async throws -> HostRecord {
        struct R: Decodable { var host: HostRecord }
        return try await send("POST", "/hosts/pair/approve", body: ["userCode": userCode], auth: true, as: R.self).host
    }

    public func hosts() async throws -> [HostRecord] {
        struct R: Decodable { var hosts: [HostRecord] }
        return try await send("GET", "/hosts", auth: true, as: R.self).hosts
    }

    public func deleteHost(id: String) async throws {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try await send("DELETE", "/hosts/\(escaped)", auth: true, as: EmptyPayload.self)
    }

    public func iceConfiguration() async throws -> ICEConfiguration {
        try await send("GET", "/ice", auth: true, as: ICEConfiguration.self)
    }

    /// The signaling WebSocket URL with a fresh access token as `?token=`.
    /// `SignalingClient` moves the token into the `Authorization` header;
    /// prefer `signalingRequest()`.
    public func signalingURL() async throws -> URL {
        configuration.signalingURL(token: try await validAccessToken())
    }

    /// The signaling WebSocket upgrade request, authenticated with an
    /// `Authorization: Bearer` header.
    public func signalingRequest() async throws -> URLRequest {
        var request = URLRequest(url: configuration.signalingURL(token: nil))
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: Tokens

    /// An access token valid for at least `refreshLeeway`, refreshing first
    /// if needed.
    public func validAccessToken() async throws -> String {
        guard let s = session else { throw BackendError.notSignedIn }
        if s.accessTokenExpiresAt.timeIntervalSinceNow > refreshLeeway { return s.accessToken }
        return try await refresh(rejecting: s.accessToken).accessToken
    }

    /// Single-flight refresh. `rejecting` is the token that failed; if the
    /// session already moved past it, the current session is returned.
    @discardableResult
    public func refresh(rejecting rejected: String? = nil) async throws -> StoredSession {
        if let rejected, let s = session, s.accessToken != rejected { return s }
        if let refreshTask { return try await refreshTask.value }
        guard let refreshToken = session?.refreshToken else { throw BackendError.notSignedIn }
        let task = Task { () throws -> StoredSession in
            let tokens = try await self.send("POST", "/auth/refresh", body: ["refreshToken": refreshToken], auth: false, as: Tokens.self)
            return StoredSession(tokens: tokens)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let s = try await task.value
            session = s
            try? tokenStore.save(s)
            return s
        } catch let BackendError.server(status, code, message) where status == 401 || status == 403 {
            clearSession()
            throw BackendError.server(status: status, code: code, message: message)
        }
    }

    private func adopt(_ tokens: Tokens) throws -> User {
        let s = StoredSession(tokens: tokens)
        session = s
        try tokenStore.save(s)
        emit(.signedIn(s.user))
        return s.user
    }

    private func clearSession() {
        let had = session != nil
        session = nil
        tokenStore.clear()
        if had { emit(.signedOut) }
    }

    // MARK: HTTP

    private func send<R: Decodable>(_ method: String, _ path: String, body: [String: String]? = nil, auth: Bool, as type: R.Type) async throws -> R {
        let bodyData = try body.map { try JSONEncoder().encode($0) }
        var token: String?
        if auth { token = try await validAccessToken() }
        do {
            return try await perform(method, path, body: bodyData, token: token, as: R.self)
        } catch BackendError.server(let status, _, _) where status == 401 && auth {
            let fresh = try await refresh(rejecting: token)
            return try await perform(method, path, body: bodyData, token: fresh.accessToken, as: R.self)
        }
    }

    private func perform<R: Decodable>(_ method: String, _ path: String, body: Data?, token: String?, as type: R.Type) async throws -> R {
        var request = URLRequest(url: configuration.url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse("not HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            if let err = try? JSONDecoder().decode(BackendErrorBody.self, from: data) {
                throw BackendError.server(status: http.statusCode, code: err.error.code, message: err.error.message)
            }
            throw BackendError.server(status: http.statusCode, code: "http_\(http.statusCode)",
                                      message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        if R.self == EmptyPayload.self { return EmptyPayload() as! R }
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw BackendError.invalidResponse("\(path): \(error)")
        }
    }
}

/// RFC 7636 proof key: a random verifier and its S256 challenge.
public struct PKCE: Sendable, Hashable {
    public let verifier: String
    public let challenge: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        self.init(verifier: Self.base64URL(Data(bytes)))
    }

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
