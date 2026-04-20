import Foundation

/// Project information
public struct Project: Sendable {
    public let id: String
    public let displayName: String
    public let config: ProjectConfig
    
    init(from json: [String: Any]) {
        self.id = json["id"] as? String ?? ""
        self.displayName = json["display_name"] as? String ?? ""
        
        if let configJson = json["config"] as? [String: Any] {
            self.config = ProjectConfig(from: configJson)
        } else {
            self.config = ProjectConfig(
                signUpEnabled: false,
                credentialEnabled: false,
                magicLinkEnabled: false,
                passkeyEnabled: false,
                oauthProviders: [],
                clientTeamCreationEnabled: false,
                clientUserDeletionEnabled: false,
                allowUserApiKeys: false,
                allowTeamApiKeys: false
            )
        }
    }
}

/// Project configuration
public struct ProjectConfig: Sendable {
    public let signUpEnabled: Bool
    public let credentialEnabled: Bool
    public let magicLinkEnabled: Bool
    public let passkeyEnabled: Bool
    public let oauthProviders: [OAuthProviderConfig]
    public let clientTeamCreationEnabled: Bool
    public let clientUserDeletionEnabled: Bool
    public let allowUserApiKeys: Bool
    public let allowTeamApiKeys: Bool
    
    init(from json: [String: Any]) {
        self.signUpEnabled = json["sign_up_enabled"] as? Bool ?? false
        self.credentialEnabled = json["credential_enabled"] as? Bool ?? false
        self.magicLinkEnabled = json["magic_link_enabled"] as? Bool ?? false
        self.passkeyEnabled = json["passkey_enabled"] as? Bool ?? false
        self.clientTeamCreationEnabled = json["client_team_creation_enabled"] as? Bool ?? false
        self.clientUserDeletionEnabled = json["client_user_deletion_enabled"] as? Bool ?? false
        self.allowUserApiKeys = json["allow_user_api_keys"] as? Bool ?? false
        self.allowTeamApiKeys = json["allow_team_api_keys"] as? Bool ?? false
        
        if let providers = json["enabled_oauth_providers"] as? [[String: Any]] {
            self.oauthProviders = providers.map { OAuthProviderConfig(id: $0["id"] as? String ?? "") }
        } else if let providers = json["oauth_providers"] as? [[String: Any]] {
            self.oauthProviders = providers.map { OAuthProviderConfig(id: $0["id"] as? String ?? "") }
        } else {
            self.oauthProviders = []
        }
    }
    
    init(
        signUpEnabled: Bool,
        credentialEnabled: Bool,
        magicLinkEnabled: Bool,
        passkeyEnabled: Bool,
        oauthProviders: [OAuthProviderConfig],
        clientTeamCreationEnabled: Bool,
        clientUserDeletionEnabled: Bool,
        allowUserApiKeys: Bool,
        allowTeamApiKeys: Bool
    ) {
        self.signUpEnabled = signUpEnabled
        self.credentialEnabled = credentialEnabled
        self.magicLinkEnabled = magicLinkEnabled
        self.passkeyEnabled = passkeyEnabled
        self.oauthProviders = oauthProviders
        self.clientTeamCreationEnabled = clientTeamCreationEnabled
        self.clientUserDeletionEnabled = clientUserDeletionEnabled
        self.allowUserApiKeys = allowUserApiKeys
        self.allowTeamApiKeys = allowTeamApiKeys
    }
}

public struct OAuthProviderConfig: Sendable {
    public let id: String
}
