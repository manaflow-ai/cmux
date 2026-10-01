import Foundation

/// A contact channel (email) associated with a user
public actor ContactChannel {
    private let client: APIClient
    
    public nonisolated let id: String
    public private(set) var value: String
    public let type: String
    public private(set) var isPrimary: Bool
    public private(set) var isVerified: Bool
    public private(set) var usedForAuth: Bool
    
    init(client: APIClient, json: [String: Any]) {
        self.client = client
        self.id = json["id"] as? String ?? ""
        self.value = json["value"] as? String ?? ""
        self.type = json["type"] as? String ?? "email"
        self.isPrimary = json["is_primary"] as? Bool ?? false
        self.isVerified = json["is_verified"] as? Bool ?? false
        self.usedForAuth = json["used_for_auth"] as? Bool ?? false
    }
    
    public func update(
        value: String? = nil,
        usedForAuth: Bool? = nil,
        isPrimary: Bool? = nil
    ) async throws {
        var body: [String: Any] = [:]
        if let value = value { body["value"] = value }
        if let usedForAuth = usedForAuth { body["used_for_auth"] = usedForAuth }
        if let isPrimary = isPrimary { body["is_primary"] = isPrimary }
        
        let (data, _) = try await client.sendRequest(
            path: "/contact-channels/\(id)",
            method: "PATCH",
            body: body,
            authenticated: true
        )
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.value = json["value"] as? String ?? self.value
            self.isPrimary = json["is_primary"] as? Bool ?? self.isPrimary
            self.isVerified = json["is_verified"] as? Bool ?? self.isVerified
            self.usedForAuth = json["used_for_auth"] as? Bool ?? self.usedForAuth
        }
    }
    
    public func delete() async throws {
        _ = try await client.sendRequest(
            path: "/contact-channels/\(id)",
            method: "DELETE",
            authenticated: true
        )
    }
    
    public func sendVerificationEmail(callbackUrl: String? = nil) async throws {
        var body: [String: Any] = [:]
        if let callbackUrl = callbackUrl {
            body["callback_url"] = callbackUrl
        }
        
        _ = try await client.sendRequest(
            path: "/contact-channels/\(id)/send-verification-email",
            method: "POST",
            body: body.isEmpty ? nil : body,
            authenticated: true
        )
    }
}
