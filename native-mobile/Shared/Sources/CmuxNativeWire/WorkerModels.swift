import Foundation

// REST models for the `cmux-next-native` Worker. JSON keys are snake_case;
// timestamps are Unix milliseconds.

public struct WorkerUser: Codable, Equatable, Sendable {
    public var id: String
    public var email: String?
    public var displayName: String?
    public var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
        case createdAt = "created_at"
    }
}

/// `POST /v1/auth/apple` body.
public struct AppleAuthRequest: Codable, Sendable {
    public var identityToken: String
    public var displayName: String?
    public init(identityToken: String, displayName: String? = nil) {
        self.identityToken = identityToken
        self.displayName = displayName
    }
    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case displayName = "display_name"
    }
}

/// `POST /v1/auth/dev` body (test accounts `*@test.cmux.dev` only).
public struct DevAuthRequest: Codable, Sendable {
    public var email: String
    public var secret: String
    public init(email: String, secret: String) {
        self.email = email
        self.secret = secret
    }
}

/// Response of both auth endpoints.
public struct AuthResponse: Codable, Equatable, Sendable {
    public var user: WorkerUser
    public var sessionToken: String
    public var expiresAt: Double

    enum CodingKeys: String, CodingKey {
        case user
        case sessionToken = "session_token"
        case expiresAt = "expires_at"
    }
}

public struct MeResponse: Codable, Equatable, Sendable {
    public var user: WorkerUser
}

/// `POST /v1/hosts/register` body.
public struct HostRegisterRequest: Codable, Sendable {
    public var name: String
    public var platform: String
    public init(name: String, platform: String) {
        self.name = name
        self.platform = platform
    }
}

public struct HostRegisterResponse: Codable, Equatable, Sendable {
    public var hostID: String
    public var hostSecret: String
    public var pairingCode: String
    public var pairingExpiresAt: Double?

    enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case hostSecret = "host_secret"
        case pairingCode = "pairing_code"
        case pairingExpiresAt = "pairing_expires_at"
    }
}

/// `POST /v1/hosts/pairing-code` response.
public struct PairingCodeResponse: Codable, Equatable, Sendable {
    public var pairingCode: String
    public var expiresAt: Double

    enum CodingKeys: String, CodingKey {
        case pairingCode = "pairing_code"
        case expiresAt = "expires_at"
    }
}

/// `POST /v1/pair` body.
public struct PairRequest: Codable, Sendable {
    public var code: String
    public init(code: String) { self.code = code }
}

public struct WorkerHost: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String
    public var createdAt: Double
    public var pairedAt: Double?
    public var online: Bool
    public var lastSeen: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, platform, online
        case createdAt = "created_at"
        case pairedAt = "paired_at"
        case lastSeen = "last_seen"
    }
}

public struct PairResponse: Codable, Equatable, Sendable {
    public var host: WorkerHost
}

public struct HostsResponse: Codable, Equatable, Sendable {
    public var hosts: [WorkerHost]
}

/// One ICE server; `urls` is a string or an array on the wire.
public struct IceServerConfig: Codable, Equatable, Sendable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    enum CodingKeys: String, CodingKey { case urls, username, credential }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try? c.decode([String].self, forKey: .urls) {
            urls = list
        } else {
            urls = [try c.decode(String.self, forKey: .urls)]
        }
        username = try c.decodeIfPresent(String.self, forKey: .username)
        credential = try c.decodeIfPresent(String.self, forKey: .credential)
    }
}

/// `GET /v1/ice` response.
public struct IceServersResponse: Codable, Equatable, Sendable {
    public var iceServers: [IceServerConfig]
    public var ttl: Double?
    public var expiresAt: Double?

    enum CodingKeys: String, CodingKey {
        case iceServers
        case ttl
        case expiresAt = "expires_at"
    }
}

/// `POST /v1/push/register` body.
public struct PushRegisterRequest: Codable, Sendable {
    public var apnsToken: String
    public var environment: String?
    public var bundleID: String?
    public init(apnsToken: String, environment: String? = nil, bundleID: String? = nil) {
        self.apnsToken = apnsToken
        self.environment = environment
        self.bundleID = bundleID
    }
    enum CodingKeys: String, CodingKey {
        case apnsToken = "apns_token"
        case environment
        case bundleID = "bundle_id"
    }
}

public struct OKResponse: Codable, Equatable, Sendable {
    public var ok: Bool
}

/// Error body: `{"error":{"code","message"}}`.
public struct WorkerErrorBody: Codable, Equatable, Sendable {
    public struct Detail: Codable, Equatable, Sendable {
        public var code: String
        public var message: String?
    }
    public var error: Detail
}
