import Foundation

/// A team/organization that users can belong to
public actor Team {
    private let client: APIClient
    
    public nonisolated let id: String
    public private(set) var displayName: String
    public private(set) var profileImageUrl: String?
    public private(set) var clientMetadata: [String: Any]
    public private(set) var clientReadOnlyMetadata: [String: Any]
    
    init(client: APIClient, json: [String: Any]) {
        self.client = client
        self.id = json["id"] as? String ?? ""
        self.displayName = json["display_name"] as? String ?? ""
        self.profileImageUrl = json["profile_image_url"] as? String
        self.clientMetadata = json["client_metadata"] as? [String: Any] ?? [:]
        self.clientReadOnlyMetadata = json["client_read_only_metadata"] as? [String: Any] ?? [:]
    }
    
    // MARK: - Update
    
    public func update(
        displayName: String? = nil,
        profileImageUrl: String? = nil,
        clientMetadata: [String: Any]? = nil
    ) async throws {
        var body: [String: Any] = [:]
        if let displayName = displayName { body["display_name"] = displayName }
        if let profileImageUrl = profileImageUrl { body["profile_image_url"] = profileImageUrl }
        if let clientMetadata = clientMetadata { body["client_metadata"] = clientMetadata }
        
        let (data, _) = try await client.sendRequest(
            path: "/teams/\(id)",
            method: "PATCH",
            body: body,
            authenticated: true
        )
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.displayName = json["display_name"] as? String ?? self.displayName
            self.profileImageUrl = json["profile_image_url"] as? String
            self.clientMetadata = json["client_metadata"] as? [String: Any] ?? self.clientMetadata
            self.clientReadOnlyMetadata = json["client_read_only_metadata"] as? [String: Any] ?? self.clientReadOnlyMetadata
        }
    }
    
    // MARK: - Delete
    
    public func delete() async throws {
        _ = try await client.sendRequest(
            path: "/teams/\(id)",
            method: "DELETE",
            authenticated: true
        )
    }
    
    // MARK: - Invite
    
    public func inviteUser(email: String, callbackUrl: String? = nil) async throws {
        var body: [String: Any] = [
            "email": email,
            "team_id": id
        ]
        if let callbackUrl = callbackUrl {
            body["callback_url"] = callbackUrl
        }
        
        _ = try await client.sendRequest(
            path: "/team-invitations/send-code",
            method: "POST",
            body: body,
            authenticated: true
        )
    }
    
    // MARK: - List Users
    
    public func listUsers() async throws -> [TeamUser] {
        let (data, _) = try await client.sendRequest(
            path: "/team-member-profiles?team_id=\(id)",
            method: "GET",
            authenticated: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }
        
        return items.map { TeamUser(from: $0) }
    }
    
    // MARK: - Invitations
    
    public func listInvitations() async throws -> [TeamInvitation] {
        let (data, _) = try await client.sendRequest(
            path: "/teams/\(id)/invitations",
            method: "GET",
            authenticated: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }
        
        return items.map { TeamInvitation(client: client, teamId: id, json: $0) }
    }
    
    // MARK: - API Keys
    
    public func listApiKeys() async throws -> [TeamApiKey] {
        let (data, _) = try await client.sendRequest(
            path: "/teams/\(id)/api-keys",
            method: "GET",
            authenticated: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }
        
        return items.map { TeamApiKey(from: $0) }
    }
    
    public func createApiKey(
        description: String,
        expiresAt: Date? = nil,
        scope: String? = nil
    ) async throws -> TeamApiKeyFirstView {
        var body: [String: Any] = ["description": description]
        if let expiresAt = expiresAt {
            body["expires_at_millis"] = Int64(expiresAt.timeIntervalSince1970 * 1000)
        }
        if let scope = scope { body["scope"] = scope }
        
        let (data, _) = try await client.sendRequest(
            path: "/teams/\(id)/api-keys",
            method: "POST",
            body: body,
            authenticated: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse API key response")
        }
        
        return TeamApiKeyFirstView(from: json)
    }
}

// MARK: - Supporting Types

public struct TeamUser: Sendable {
    public let id: String
    public let teamProfile: TeamMemberProfile
    
    init(from json: [String: Any]) {
        // Try both "id" (from /users?team_id=) and "user_id" (from other endpoints)
        self.id = json["id"] as? String ?? json["user_id"] as? String ?? ""
        
        if let profile = json["team_profile"] as? [String: Any] {
            self.teamProfile = TeamMemberProfile(
                displayName: profile["display_name"] as? String,
                profileImageUrl: profile["profile_image_url"] as? String
            )
        } else {
            // If no team_profile, use display_name from user itself
            self.teamProfile = TeamMemberProfile(
                displayName: json["display_name"] as? String,
                profileImageUrl: json["profile_image_url"] as? String
            )
        }
    }
}

public struct TeamMemberProfile: Sendable {
    public let displayName: String?
    public let profileImageUrl: String?
}

public actor TeamInvitation {
    private let client: APIClient
    private let teamId: String
    
    public nonisolated let id: String
    public let recipientEmail: String?
    public let expiresAt: Date
    
    init(client: APIClient, teamId: String, json: [String: Any]) {
        self.client = client
        self.teamId = teamId
        self.id = json["id"] as? String ?? ""
        self.recipientEmail = json["recipient_email"] as? String
        
        let millis = json["expires_at_millis"] as? Int64 ?? 0
        self.expiresAt = Date(timeIntervalSince1970: Double(millis) / 1000.0)
    }
    
    public func revoke() async throws {
        _ = try await client.sendRequest(
            path: "/teams/\(teamId)/invitations/\(id)",
            method: "DELETE",
            authenticated: true
        )
    }
}
