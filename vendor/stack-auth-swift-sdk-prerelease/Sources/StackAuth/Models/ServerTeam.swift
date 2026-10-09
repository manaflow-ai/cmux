import Foundation

/// Server-side team with elevated access and server metadata
public actor ServerTeam {
    private let client: APIClient
    
    public nonisolated let id: String
    public private(set) var displayName: String
    public private(set) var profileImageUrl: String?
    public private(set) var clientMetadata: [String: Any]
    public private(set) var clientReadOnlyMetadata: [String: Any]
    public private(set) var serverMetadata: [String: Any]
    public let createdAt: Date
    
    init(client: APIClient, json: [String: Any]) {
        self.client = client
        self.id = json["id"] as? String ?? ""
        self.displayName = json["display_name"] as? String ?? ""
        self.profileImageUrl = json["profile_image_url"] as? String
        self.clientMetadata = json["client_metadata"] as? [String: Any] ?? [:]
        self.clientReadOnlyMetadata = json["client_read_only_metadata"] as? [String: Any] ?? [:]
        self.serverMetadata = json["server_metadata"] as? [String: Any] ?? [:]
        
        let createdMillis = json["created_at_millis"] as? Int64 ?? 0
        self.createdAt = Date(timeIntervalSince1970: Double(createdMillis) / 1000.0)
    }
    
    // MARK: - Update
    
    public func update(
        displayName: String? = nil,
        profileImageUrl: String? = nil,
        clientMetadata: [String: Any]? = nil,
        clientReadOnlyMetadata: [String: Any]? = nil,
        serverMetadata: [String: Any]? = nil
    ) async throws {
        var body: [String: Any] = [:]
        if let displayName = displayName { body["display_name"] = displayName }
        if let url = profileImageUrl { body["profile_image_url"] = url }
        if let clientMeta = clientMetadata { body["client_metadata"] = clientMeta }
        if let clientReadOnly = clientReadOnlyMetadata { body["client_read_only_metadata"] = clientReadOnly }
        if let serverMeta = serverMetadata { body["server_metadata"] = serverMeta }
        
        let (data, _) = try await client.sendRequest(
            path: "/teams/\(id)",
            method: "PATCH",
            body: body,
            serverOnly: true
        )
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.displayName = json["display_name"] as? String ?? self.displayName
            self.profileImageUrl = json["profile_image_url"] as? String
            self.clientMetadata = json["client_metadata"] as? [String: Any] ?? self.clientMetadata
            self.clientReadOnlyMetadata = json["client_read_only_metadata"] as? [String: Any] ?? self.clientReadOnlyMetadata
            self.serverMetadata = json["server_metadata"] as? [String: Any] ?? self.serverMetadata
        }
    }
    
    // MARK: - Delete
    
    public func delete() async throws {
        _ = try await client.sendRequest(
            path: "/teams/\(id)",
            method: "DELETE",
            serverOnly: true
        )
    }
    
    // MARK: - Users
    
    public func listUsers() async throws -> [TeamUser] {
        let (data, _) = try await client.sendRequest(
            path: "/users?team_id=\(id)",
            method: "GET",
            serverOnly: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }
        
        return items.map { TeamUser(from: $0) }
    }
    
    public func addUser(id userId: String) async throws {
        _ = try await client.sendRequest(
            path: "/team-memberships/\(id)/\(userId)",
            method: "POST",
            serverOnly: true
        )
    }
    
    public func removeUser(id userId: String) async throws {
        _ = try await client.sendRequest(
            path: "/team-memberships/\(id)/\(userId)",
            method: "DELETE",
            serverOnly: true
        )
    }
    
    // MARK: - Invitations
    
    public func inviteUser(email: String, callbackUrl: String? = nil) async throws {
        var body: [String: Any] = [
            "email": email,
            "team_id": id
        ]
        if let url = callbackUrl { body["callback_url"] = url }
        
        _ = try await client.sendRequest(
            path: "/team-invitations/send-code",
            method: "POST",
            body: body,
            serverOnly: true
        )
    }
    
    public func listInvitations() async throws -> [TeamInvitation] {
        let (data, _) = try await client.sendRequest(
            path: "/teams/\(id)/invitations",
            method: "GET",
            serverOnly: true
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
            serverOnly: true
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
            serverOnly: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse API key response")
        }
        
        return TeamApiKeyFirstView(from: json)
    }
}
