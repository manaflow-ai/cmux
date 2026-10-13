import Foundation

public struct User: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var email: String?
    public var name: String?
    public init(id: String, email: String?, name: String?) { self.id = id; self.email = email; self.name = name }

    public var displayName: String { name?.isEmpty == false ? name! : (email ?? "cmux user") }
}

/// PROTOCOL §5 `Tokens`.
public struct Tokens: Codable, Sendable, Hashable {
    public var accessToken: String
    public var refreshToken: String
    /// Seconds until `accessToken` expires.
    public var expiresIn: Int
    public var user: User
    public init(accessToken: String, refreshToken: String, expiresIn: Int, user: User) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresIn = expiresIn; self.user = user
    }
}

/// A paired Mac, as listed by `GET /hosts`.
public struct HostRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var os: String
    public var online: Bool
    public var lastSeenAt: EpochMillis?
    public var createdAt: EpochMillis
    public init(id: String, name: String, os: String, online: Bool, lastSeenAt: EpochMillis?, createdAt: EpochMillis) {
        self.id = id; self.name = name; self.os = os; self.online = online; self.lastSeenAt = lastSeenAt; self.createdAt = createdAt
    }
}

public struct ICEServer: Codable, Sendable, Hashable {
    public var urls: [String]
    public var username: String?
    public var credential: String?
    public init(urls: [String], username: String? = nil, credential: String? = nil) { self.urls = urls; self.username = username; self.credential = credential }

    enum CodingKeys: String, CodingKey { case urls, username, credential }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try? c.decode([String].self, forKey: .urls) { urls = list } else { urls = [try c.decode(String.self, forKey: .urls)] }
        username = try c.decodeIfPresent(String.self, forKey: .username)
        credential = try c.decodeIfPresent(String.self, forKey: .credential)
    }
}

/// `GET /ice` result.
public struct ICEConfiguration: Codable, Sendable, Hashable {
    public var iceServers: [ICEServer]
    /// Seconds the credentials stay valid.
    public var ttl: Int
    public init(iceServers: [ICEServer], ttl: Int) { self.iceServers = iceServers; self.ttl = ttl }
}

public struct PairStartResult: Codable, Sendable, Hashable {
    public var deviceCode: String; public var userCode: String; public var expiresAt: EpochMillis; public var interval: Int
    public init(deviceCode: String, userCode: String, expiresAt: EpochMillis, interval: Int) {
        self.deviceCode = deviceCode; self.userCode = userCode; self.expiresAt = expiresAt; self.interval = interval
    }
}

public struct PairPollResult: Codable, Sendable, Hashable {
    public var status: String
    public var hostId: String?
    public var hostToken: String?
    public var userId: String?
    public init(status: String, hostId: String? = nil, hostToken: String? = nil, userId: String? = nil) {
        self.status = status; self.hostId = hostId; self.hostToken = hostToken; self.userId = userId
    }
}

/// Backend error body `{error:{code,message}}`.
public struct BackendErrorBody: Codable, Sendable, Hashable {
    public struct Detail: Codable, Sendable, Hashable { public var code: String; public var message: String }
    public var error: Detail
}

/// Online state of one host, from signaling `welcome` and `presence`.
public struct HostPresence: Codable, Sendable, Hashable {
    public var hostId: String
    public var online: Bool
    public init(hostId: String, online: Bool) { self.hostId = hostId; self.online = online }
}
