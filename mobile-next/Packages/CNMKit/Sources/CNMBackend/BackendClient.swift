import Foundation

public struct BackendUser: Sendable, Hashable, Codable {
    public var id: String
    public var email: String?
    public var displayName: String?
    public var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
        case createdAt = "created_at"
    }

    public init(id: String, email: String?, displayName: String?, createdAt: String? = nil) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

public struct BackendSession: Sendable, Hashable, Codable {
    public var accessToken: String
    public var accessExpiresAt: String
    public var refreshToken: String
    public var user: BackendUser
    public var isNewUser: Bool?

    enum CodingKeys: String, CodingKey {
        case user
        case accessToken = "access_token"
        case accessExpiresAt = "access_expires_at"
        case refreshToken = "refresh_token"
        case isNewUser = "is_new_user"
    }

    public init(accessToken: String, accessExpiresAt: String, refreshToken: String, user: BackendUser, isNewUser: Bool? = nil) {
        self.accessToken = accessToken
        self.accessExpiresAt = accessExpiresAt
        self.refreshToken = refreshToken
        self.user = user
        self.isNewUser = isNewUser
    }

    /// `access_expires_at` is ISO 8601.
    public var accessExpiry: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: accessExpiresAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: accessExpiresAt) ?? .distantPast
    }
}

public struct BackendHost: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String?
    public var appVersion: String?
    public var lastSeenAt: String?
    public var online: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, platform, online
        case appVersion = "app_version"
        case lastSeenAt = "last_seen_at"
    }

    public init(id: String, name: String, platform: String? = nil, appVersion: String? = nil, lastSeenAt: String? = nil, online: Bool? = nil) {
        self.id = id
        self.name = name
        self.platform = platform
        self.appVersion = appVersion
        self.lastSeenAt = lastSeenAt
        self.online = online
    }
}

public struct BackendICEServer: Sendable, Hashable, Codable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try? container.decode([String].self, forKey: .urls) {
            urls = list
        } else {
            urls = [try container.decode(String.self, forKey: .urls)]
        }
        username = try container.decodeIfPresent(String.self, forKey: .username)
        credential = try container.decodeIfPresent(String.self, forKey: .credential)
    }

    public init(urls: [String], username: String?, credential: String?) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

public struct PairingStart: Sendable, Hashable, Codable {
    public var pairingID: String
    public var code: String
    public var pollSecret: String
    public var expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case code
        case pairingID = "pairing_id"
        case pollSecret = "poll_secret"
        case expiresAt = "expires_at"
    }
}

public struct PairingPoll: Sendable, Hashable, Codable {
    public var status: String
    public var hostID: String?
    public var hostToken: String?
    public var user: BackendUser?

    enum CodingKeys: String, CodingKey {
        case status, user
        case hostID = "host_id"
        case hostToken = "host_token"
    }
}

public struct BackendError: Error, Sendable, Hashable, LocalizedError {
    public var status: Int
    public var code: String
    public var message: String

    public var errorDescription: String? { message }

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }
}

/// HTTP client for the cmux-next mobile backend (`docs/API.md`).
public struct BackendClient: Sendable {
    public static let productionURL = URL(string: "https://cmux-next-mobile-native.debussy.workers.dev")!

    public var baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = BackendClient.productionURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Auth

    public func startEmail(_ email: String) async throws {
        _ = try await send("POST", "v1/auth/email/start", body: ["email": email]) as EmptyReply
    }

    public func verifyEmail(_ email: String, code: String) async throws -> BackendSession {
        try await send("POST", "v1/auth/email/verify", body: ["email": email, "code": code])
    }

    public func signInWithApple(identityToken: String, rawNonce: String, givenName: String?, familyName: String?) async throws -> BackendSession {
        var body = ["identity_token": identityToken, "raw_nonce": rawNonce]
        body["given_name"] = givenName
        body["family_name"] = familyName
        return try await send("POST", "v1/auth/apple", body: body)
    }

    public func refresh(_ refreshToken: String) async throws -> BackendSession {
        try await send("POST", "v1/auth/refresh", body: ["refresh_token": refreshToken])
    }

    public func logout(_ refreshToken: String) async throws {
        _ = try await send("POST", "v1/auth/logout", body: ["refresh_token": refreshToken]) as EmptyReply
    }

    public func me(token: String) async throws -> BackendUser {
        try await send("GET", "v1/me", token: token)
    }

    public func updateMe(token: String, displayName: String) async throws -> BackendUser {
        try await send("PATCH", "v1/me", token: token, body: ["display_name": displayName])
    }

    public func deleteAccount(token: String) async throws {
        _ = try await send("DELETE", "v1/me", token: token) as EmptyReply
    }

    // MARK: Hosts and pairing

    public func hosts(token: String) async throws -> [BackendHost] {
        struct Reply: Decodable { var hosts: [BackendHost] }
        let reply: Reply = try await send("GET", "v1/hosts", token: token)
        return reply.hosts
    }

    public func renameHost(token: String, id: String, name: String) async throws -> BackendHost {
        try await send("PATCH", "v1/hosts/\(id)", token: token, body: ["name": name])
    }

    public func removeHost(token: String, id: String) async throws {
        _ = try await send("DELETE", "v1/hosts/\(id)", token: token) as EmptyReply
    }

    public func claimPairing(token: String, code: String) async throws -> BackendHost {
        struct Reply: Decodable { var host: BackendHost }
        let reply: Reply = try await send("POST", "v1/pairing/claim", token: token, body: ["code": code])
        return reply.host
    }

    public func startPairing(hostName: String, platform: String, appVersion: String) async throws -> PairingStart {
        try await send("POST", "v1/pairing/start", body: ["host_name": hostName, "platform": platform, "app_version": appVersion])
    }

    public func pollPairing(_ start: PairingStart) async throws -> PairingPoll {
        let secret = start.pollSecret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? start.pollSecret
        return try await send("GET", "v1/pairing/\(start.pairingID)?poll_secret=\(secret)")
    }

    /// The Mac removes itself from the account (its token stops working).
    public func unpairHost(token: String) async throws {
        _ = try await send("DELETE", "v1/host/me", token: token) as EmptyReply
    }

    public func approvePairing(_ start: PairingStart) async throws {
        _ = try await send("POST", "v1/pairing/\(start.pairingID)/approve", body: ["poll_secret": start.pollSecret]) as EmptyReply
    }

    public func rejectPairing(_ start: PairingStart) async throws {
        _ = try await send("POST", "v1/pairing/\(start.pairingID)/reject", body: ["poll_secret": start.pollSecret]) as EmptyReply
    }

    public func iceServers(token: String) async throws -> [BackendICEServer] {
        struct Reply: Decodable {
            var iceServers: [BackendICEServer]
            enum CodingKeys: String, CodingKey { case iceServers = "ice_servers" }
        }
        let reply: Reply = try await send("GET", "v1/ice", token: token)
        return reply.iceServers
    }

    // MARK: Transport

    private struct EmptyReply: Decodable {}

    private struct ErrorReply: Decodable {
        struct Inner: Decodable { var code: String; var message: String? }
        var error: Inner
    }

    private func send<Reply: Decodable>(
        _ method: String, _ path: String, token: String? = nil, body: [String: String]? = nil
    ) async throws -> Reply {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw BackendError(status: 0, code: "bad_url", message: "Bad URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let reply = try? JSONDecoder().decode(ErrorReply.self, from: data) {
                throw BackendError(status: status, code: reply.error.code, message: reply.error.message ?? reply.error.code)
            }
            throw BackendError(status: status, code: "http_\(status)", message: "The server returned \(status).")
        }
        if Reply.self == EmptyReply.self, data.isEmpty || (try? JSONDecoder().decode(Reply.self, from: data)) == nil {
            return try JSONDecoder().decode(Reply.self, from: Data("{}".utf8))
        }
        return try JSONDecoder().decode(Reply.self, from: data)
    }
}
