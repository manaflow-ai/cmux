import Foundation

/// Base API key properties
public struct ApiKeyBase: Sendable {
    public let id: String
    public let description: String
    public let expiresAt: Date?
    public let createdAt: Date
    public let isValid: Bool
    
    init(from json: [String: Any]) {
        self.id = json["id"] as? String ?? ""
        self.description = json["description"] as? String ?? ""
        
        if let expiresMillis = json["expires_at_millis"] as? Int64 ?? json["expires_at"] as? Int64 {
            self.expiresAt = Date(timeIntervalSince1970: Double(expiresMillis) / 1000.0)
        } else {
            self.expiresAt = nil
        }
        
        let createdMillis = json["created_at_millis"] as? Int64 ?? json["created_at"] as? Int64 ?? 0
        self.createdAt = Date(timeIntervalSince1970: Double(createdMillis) / 1000.0)
        
        self.isValid = json["is_valid"] as? Bool ?? true
    }
}

/// User API key
public struct UserApiKey: Sendable {
    public let base: ApiKeyBase
    public let userId: String
    public let teamId: String?
    
    public var id: String { base.id }
    public var description: String { base.description }
    public var expiresAt: Date? { base.expiresAt }
    public var createdAt: Date { base.createdAt }
    public var isValid: Bool { base.isValid }
    
    init(from json: [String: Any]) {
        self.base = ApiKeyBase(from: json)
        self.userId = json["user_id"] as? String ?? ""
        self.teamId = json["team_id"] as? String
    }
}

/// User API key with the key value (only returned on creation)
public struct UserApiKeyFirstView: Sendable {
    public let base: UserApiKey
    public let apiKey: String
    
    public var id: String { base.id }
    public var description: String { base.description }
    public var expiresAt: Date? { base.expiresAt }
    public var createdAt: Date { base.createdAt }
    public var isValid: Bool { base.isValid }
    public var userId: String { base.userId }
    public var teamId: String? { base.teamId }
    
    init(from json: [String: Any]) {
        self.base = UserApiKey(from: json)
        self.apiKey = json["api_key"] as? String ?? ""
    }
}

/// Team API key
public struct TeamApiKey: Sendable {
    public let base: ApiKeyBase
    public let teamId: String
    
    public var id: String { base.id }
    public var description: String { base.description }
    public var expiresAt: Date? { base.expiresAt }
    public var createdAt: Date { base.createdAt }
    public var isValid: Bool { base.isValid }
    
    init(from json: [String: Any]) {
        self.base = ApiKeyBase(from: json)
        self.teamId = json["team_id"] as? String ?? ""
    }
}

/// Team API key with the key value (only returned on creation)
public struct TeamApiKeyFirstView: Sendable {
    public let base: TeamApiKey
    public let apiKey: String
    
    public var id: String { base.id }
    public var description: String { base.description }
    public var expiresAt: Date? { base.expiresAt }
    public var createdAt: Date { base.createdAt }
    public var isValid: Bool { base.isValid }
    public var teamId: String { base.teamId }
    
    init(from json: [String: Any]) {
        self.base = TeamApiKey(from: json)
        self.apiKey = json["api_key"] as? String ?? ""
    }
}
