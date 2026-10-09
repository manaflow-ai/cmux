import Foundation

/// Server-side Stack Auth client with elevated privileges
public actor StackServerApp {
    public let projectId: String
    
    let client: APIClient
    
    public init(
        projectId: String,
        publishableClientKey: String,
        secretServerKey: String,
        baseUrl: String = "https://api.stack-auth.com"
    ) {
        self.projectId = projectId
        
        self.client = APIClient(
            baseUrl: baseUrl,
            projectId: projectId,
            publishableClientKey: publishableClientKey,
            secretServerKey: secretServerKey,
            tokenStore: NullTokenStore()
        )
    }
    
    // MARK: - Users
    
    public func listUsers(
        limit: Int? = nil,
        cursor: String? = nil,
        orderBy: String? = nil,
        descending: Bool? = nil
    ) async throws -> PaginatedResult<ServerUser> {
        var query: [String] = []
        if let limit = limit { query.append("limit=\(limit)") }
        if let cursor = cursor { query.append("cursor=\(cursor)") }
        if let orderBy = orderBy { query.append("order_by=\(orderBy)") }
        if let desc = descending { query.append("desc=\(desc)") }
        
        var path = "/users"
        if !query.isEmpty {
            path += "?" + query.joined(separator: "&")
        }
        
        let (data, _) = try await client.sendRequest(
            path: path,
            method: "GET",
            serverOnly: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return PaginatedResult(items: [], pagination: Pagination(hasPreviousPage: false, hasNextPage: false, startCursor: nil, endCursor: nil))
        }
        
        let pagination = parsePagination(from: json)
        return PaginatedResult(
            items: items.map { ServerUser(client: client, json: $0) },
            pagination: pagination
        )
    }
    
    public func getUser(id userId: String) async throws -> ServerUser? {
        do {
            let (data, _) = try await client.sendRequest(
                path: "/users/\(userId)",
                method: "GET",
                serverOnly: true
            )
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            
            return ServerUser(client: client, json: json)
        } catch let error as StackAuthErrorProtocol where error.code == "USER_NOT_FOUND" {
            return nil
        }
    }
    
    public func createUser(
        email: String? = nil,
        password: String? = nil,
        displayName: String? = nil,
        primaryEmailAuthEnabled: Bool = false,
        primaryEmailVerified: Bool = false,
        clientMetadata: [String: Any]? = nil,
        serverMetadata: [String: Any]? = nil,
        otpAuthEnabled: Bool = false,
        totpSecretBase32: String? = nil,
        selectedTeamId: String? = nil,
        profileImageUrl: String? = nil
    ) async throws -> ServerUser {
        var body: [String: Any] = [:]
        if let email = email { body["primary_email"] = email }
        if let password = password { body["password"] = password }
        if let displayName = displayName { body["display_name"] = displayName }
        body["primary_email_auth_enabled"] = primaryEmailAuthEnabled
        body["primary_email_verified"] = primaryEmailVerified
        if let clientMetadata = clientMetadata { body["client_metadata"] = clientMetadata }
        if let serverMetadata = serverMetadata { body["server_metadata"] = serverMetadata }
        body["otp_auth_enabled"] = otpAuthEnabled
        if let totp = totpSecretBase32 { body["totp_secret_base32"] = totp }
        if let teamId = selectedTeamId { body["selected_team_id"] = teamId }
        if let url = profileImageUrl { body["profile_image_url"] = url }
        
        let (data, _) = try await client.sendRequest(
            path: "/users",
            method: "POST",
            body: body,
            serverOnly: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse user response")
        }
        
        return ServerUser(client: client, json: json)
    }
    
    // MARK: - Teams
    
    public func listTeams(
        userId: String? = nil
    ) async throws -> [ServerTeam] {
        var query: [String] = []
        if let userId = userId { query.append("user_id=\(userId)") }
        
        var path = "/teams"
        if !query.isEmpty {
            path += "?" + query.joined(separator: "&")
        }
        
        let (data, _) = try await client.sendRequest(
            path: path,
            method: "GET",
            serverOnly: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }
        
        return items.map { ServerTeam(client: client, json: $0) }
    }
    
    public func getTeam(id teamId: String) async throws -> ServerTeam? {
        do {
            let (data, _) = try await client.sendRequest(
                path: "/teams/\(teamId)",
                method: "GET",
                serverOnly: true
            )
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            
            return ServerTeam(client: client, json: json)
        } catch let error as StackAuthErrorProtocol where error.code == "TEAM_NOT_FOUND" {
            return nil
        }
    }
    
    public func createTeam(
        displayName: String,
        creatorUserId: String? = nil,
        profileImageUrl: String? = nil,
        clientMetadata: [String: Any]? = nil,
        serverMetadata: [String: Any]? = nil
    ) async throws -> ServerTeam {
        var body: [String: Any] = ["display_name": displayName]
        if let creatorId = creatorUserId { body["creator_user_id"] = creatorId }
        if let url = profileImageUrl { body["profile_image_url"] = url }
        if let clientMeta = clientMetadata { body["client_metadata"] = clientMeta }
        if let serverMeta = serverMetadata { body["server_metadata"] = serverMeta }
        
        let (data, _) = try await client.sendRequest(
            path: "/teams",
            method: "POST",
            body: body,
            serverOnly: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse team response")
        }
        
        return ServerTeam(client: client, json: json)
    }
    
    // MARK: - Project
    
    public func getProject() async throws -> Project {
        let (data, _) = try await client.sendRequest(
            path: "/projects/current",
            method: "GET",
            serverOnly: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse project response")
        }
        
        return Project(from: json)
    }
    
    // MARK: - Create Session (Impersonation)
    
    public func createSession(userId: String, expiresInSeconds: Int = 3600) async throws -> SessionTokens {
        let body: [String: Any] = [
            "user_id": userId,
            "expires_in_millis": expiresInSeconds * 1000
        ]
        
        let (data, _) = try await client.sendRequest(
            path: "/auth/sessions",
            method: "POST",
            body: body,
            serverOnly: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse session response")
        }
        
        return SessionTokens(
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }
    
    // MARK: - Helpers
    
    private func parsePagination(from json: [String: Any]) -> Pagination {
        let pagination = json["pagination"] as? [String: Any] ?? [:]
        return Pagination(
            hasPreviousPage: pagination["has_previous_page"] as? Bool ?? false,
            hasNextPage: pagination["has_next_page"] as? Bool ?? false,
            startCursor: pagination["start_cursor"] as? String,
            endCursor: pagination["end_cursor"] as? String
        )
    }
}

// MARK: - Supporting Types

public struct PaginatedResult<T: Sendable>: Sendable {
    public let items: [T]
    public let pagination: Pagination
}

public struct Pagination: Sendable {
    public let hasPreviousPage: Bool
    public let hasNextPage: Bool
    public let startCursor: String?
    public let endCursor: String?
}

public struct SessionTokens: Sendable {
    public let accessToken: String
    public let refreshToken: String
}
