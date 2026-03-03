import Foundation

/// The authenticated current user with methods to modify their data
public actor CurrentUser {
    private let client: APIClient
    private var userData: User
    public let selectedTeam: Team?
    
    // User properties (delegated to userData)
    public var id: String { userData.id }
    public var displayName: String? { userData.displayName }
    public var primaryEmail: String? { userData.primaryEmail }
    public var primaryEmailVerified: Bool { userData.primaryEmailVerified }
    public var profileImageUrl: String? { userData.profileImageUrl }
    public var signedUpAt: Date { userData.signedUpAt }
    public var clientMetadata: [String: Any] { userData.clientMetadata }
    public var clientReadOnlyMetadata: [String: Any] { userData.clientReadOnlyMetadata }
    public var hasPassword: Bool { userData.hasPassword }
    public var emailAuthEnabled: Bool { userData.emailAuthEnabled }
    public var otpAuthEnabled: Bool { userData.otpAuthEnabled }
    public var passkeyAuthEnabled: Bool { userData.passkeyAuthEnabled }
    public var isMultiFactorRequired: Bool { userData.isMultiFactorRequired }
    public var isAnonymous: Bool { userData.isAnonymous }
    public var isRestricted: Bool { userData.isRestricted }
    public var restrictedReason: User.RestrictedReason? { userData.restrictedReason }
    public var oauthProviders: [User.OAuthProviderInfo] { userData.oauthProviders }
    
    init(client: APIClient, json: [String: Any]) {
        self.client = client
        self.userData = User(from: json)
        
        if let teamJson = json["selected_team"] as? [String: Any] {
            self.selectedTeam = Team(client: client, json: teamJson)
        } else {
            self.selectedTeam = nil
        }
    }
    
    // MARK: - Update Methods
    
    public func update(
        displayName: String? = nil,
        clientMetadata: [String: Any]? = nil,
        selectedTeamId: String? = nil,
        profileImageUrl: String? = nil
    ) async throws {
        var body: [String: Any] = [:]
        if let displayName = displayName { body["display_name"] = displayName }
        if let clientMetadata = clientMetadata { body["client_metadata"] = clientMetadata }
        if let selectedTeamId = selectedTeamId { body["selected_team_id"] = selectedTeamId }
        if let profileImageUrl = profileImageUrl { body["profile_image_url"] = profileImageUrl }
        
        let (data, _) = try await client.sendRequest(
            path: "/users/me",
            method: "PATCH",
            body: body,
            authenticated: true
        )
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.userData = User(from: json)
        }
    }
    
    public func setDisplayName(_ displayName: String?) async throws {
        try await update(displayName: displayName)
    }
    
    public func setClientMetadata(_ metadata: [String: Any]) async throws {
        try await update(clientMetadata: metadata)
    }
    
    public func setSelectedTeam(_ team: Team?) async throws {
        try await update(selectedTeamId: team?.id)
    }
    
    public func setSelectedTeam(id teamId: String?) async throws {
        try await update(selectedTeamId: teamId)
    }
    
    // MARK: - Delete
    
    public func delete() async throws {
        _ = try await client.sendRequest(
            path: "/users/me",
            method: "DELETE",
            authenticated: true
        )
        await client.clearTokens()
    }
    
    // MARK: - Password Methods
    
    public func updatePassword(oldPassword: String, newPassword: String) async throws {
        _ = try await client.sendRequest(
            path: "/auth/password/update",
            method: "POST",
            body: [
                "old_password": oldPassword,
                "new_password": newPassword
            ],
            authenticated: true
        )
    }
    
    public func setPassword(_ password: String) async throws {
        _ = try await client.sendRequest(
            path: "/auth/password/set",
            method: "POST",
            body: ["password": password],
            authenticated: true
        )
    }
    
    // MARK: - Team Methods
    
    public func listTeams() async throws -> [Team] {
        let (data, _) = try await client.sendRequest(
            path: "/teams?user_id=me",
            method: "GET",
            authenticated: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }
        
        return items.map { Team(client: client, json: $0) }
    }
    
    public func getTeam(id teamId: String) async throws -> Team? {
        let teams = try await listTeams()
        return teams.first { $0.id == teamId }
    }
    
    public func createTeam(displayName: String, profileImageUrl: String? = nil) async throws -> Team {
        var body: [String: Any] = [
            "display_name": displayName,
            "creator_user_id": "me"
        ]
        if let url = profileImageUrl {
            body["profile_image_url"] = url
        }
        
        let (data, _) = try await client.sendRequest(
            path: "/teams",
            method: "POST",
            body: body,
            authenticated: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse team response")
        }
        
        let team = Team(client: client, json: json)
        try await setSelectedTeam(team)
        return team
    }
    
    public func leaveTeam(_ team: Team) async throws {
        _ = try await client.sendRequest(
            path: "/teams/\(team.id)/users/me",
            method: "DELETE",
            authenticated: true
        )
    }
    
    // MARK: - Contact Channel Methods
    
    public func listContactChannels() async throws -> [ContactChannel] {
        let (data, _) = try await client.sendRequest(
            path: "/contact-channels?user_id=me",
            method: "GET",
            authenticated: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }
        
        return items.map { ContactChannel(client: client, json: $0) }
    }
    
    public func createContactChannel(
        type: String = "email",
        value: String,
        usedForAuth: Bool,
        isPrimary: Bool = false
    ) async throws -> ContactChannel {
        let (data, _) = try await client.sendRequest(
            path: "/contact-channels",
            method: "POST",
            body: [
                "type": type,
                "value": value,
                "used_for_auth": usedForAuth,
                "is_primary": isPrimary,
                "user_id": "me"
            ],
            authenticated: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse contact channel response")
        }
        
        return ContactChannel(client: client, json: json)
    }
    
    // MARK: - Session Methods
    
    public func getActiveSessions() async throws -> [ActiveSession] {
        let (data, _) = try await client.sendRequest(
            path: "/users/me/sessions",
            method: "GET",
            authenticated: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }
        
        return items.map { ActiveSession(from: $0) }
    }
    
    public func revokeSession(id sessionId: String) async throws {
        _ = try await client.sendRequest(
            path: "/users/me/sessions/\(sessionId)",
            method: "DELETE",
            authenticated: true
        )
    }
    
    // MARK: - Auth Methods
    
    public func signOut() async throws {
        // Ignore errors - session may already be invalid
        _ = try? await client.sendRequest(
            path: "/auth/sessions/current",
            method: "DELETE",
            authenticated: true
        )
        await client.clearTokens()
    }
    
    public func getAccessToken() async -> String? {
        return await client.getAccessToken()
    }
    
    public func getRefreshToken() async -> String? {
        return await client.getRefreshToken()
    }
    
    public func getAuthHeaders() async -> [String: String] {
        let accessToken = await client.getAccessToken()
        let refreshToken = await client.getRefreshToken()
        
        // Build JSON object with only non-nil values
        // JSONSerialization cannot serialize nil, so we must filter them out
        var json: [String: Any] = [:]
        if let accessToken = accessToken {
            json["accessToken"] = accessToken
        }
        if let refreshToken = refreshToken {
            json["refreshToken"] = refreshToken
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let string = String(data: data, encoding: .utf8) {
            return ["x-stack-auth": string]
        }
        
        return ["x-stack-auth": "{}"]
    }
    
    // MARK: - Permission Methods
    
    public func hasPermission(id permissionId: String, team: Team? = nil) async throws -> Bool {
        let permission = try await getPermission(id: permissionId, team: team)
        return permission != nil
    }
    
    public func getPermission(id permissionId: String, team: Team? = nil) async throws -> TeamPermission? {
        let permissions = try await listPermissions(team: team)
        return permissions.first { $0.id == permissionId }
    }
    
    public func listPermissions(team: Team? = nil, recursive: Bool = true) async throws -> [TeamPermission] {
        var path = "/users/me/permissions"
        var query: [String] = []
        
        if let team = team {
            query.append("team_id=\(team.id)")
        }
        query.append("recursive=\(recursive)")
        
        if !query.isEmpty {
            path += "?" + query.joined(separator: "&")
        }
        
        let (data, _) = try await client.sendRequest(
            path: path,
            method: "GET",
            authenticated: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }
        
        return items.map { TeamPermission(id: $0["id"] as? String ?? "") }
    }
    
    // MARK: - API Key Methods
    
    public func listApiKeys() async throws -> [UserApiKey] {
        let (data, _) = try await client.sendRequest(
            path: "/users/me/api-keys",
            method: "GET",
            authenticated: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }
        
        return items.map { UserApiKey(from: $0) }
    }
    
    public func createApiKey(
        description: String,
        expiresAt: Date? = nil,
        scope: String? = nil,
        teamId: String? = nil
    ) async throws -> UserApiKeyFirstView {
        var body: [String: Any] = ["description": description]
        if let expiresAt = expiresAt {
            body["expires_at_millis"] = Int64(expiresAt.timeIntervalSince1970 * 1000)
        }
        if let scope = scope { body["scope"] = scope }
        if let teamId = teamId { body["team_id"] = teamId }
        
        let (data, _) = try await client.sendRequest(
            path: "/users/me/api-keys",
            method: "POST",
            body: body,
            authenticated: true
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse API key response")
        }
        
        return UserApiKeyFirstView(from: json)
    }
}
