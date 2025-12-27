import Foundation
import SwiftUI

@MainActor
class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var isAuthenticated = false
    @Published var currentUser: StackAuthClient.User?
    @Published var isLoading = false

    private let client = StackAuthClient.shared
    private let keychain = KeychainHelper.shared

    private init() {
        // Check for existing session on launch
        Task {
            await checkExistingSession()
        }
    }

    // MARK: - Session Management

    private func checkExistingSession() async {
        let hasRefresh = keychain.get("refresh_token")
        let hasAccess = keychain.get("access_token")
        print("🔐 Checking session - refresh: \(hasRefresh != nil), access: \(hasAccess != nil)")

        guard let refreshToken = hasRefresh else {
            print("🔐 No refresh token found in keychain")
            return
        }

        do {
            let accessToken = try await client.refreshAccessToken(refreshToken: refreshToken)
            keychain.set(accessToken, forKey: "access_token")

            let user = try await client.getCurrentUser(accessToken: accessToken)
            self.currentUser = user
            self.isAuthenticated = true
            print("🔐 Session restored for \(user.primary_email ?? "unknown")")

            // Sync with Convex
            await ConvexClientManager.shared.syncAuth()
        } catch {
            print("🔐 Session restore failed: \(error)")
            // Session invalid, clear tokens
            keychain.delete("refresh_token")
            keychain.delete("access_token")
        }
    }

    // MARK: - Sign In Flow

    private var pendingNonce: String?
    private var pendingEmail: String?

    func sendCode(to email: String) async throws {
        isLoading = true
        defer { isLoading = false }

        let nonce = try await client.sendSignInCode(email: email)
        pendingNonce = nonce
        pendingEmail = email
    }

    func verifyCode(_ code: String) async throws {
        guard let nonce = pendingNonce else {
            throw AuthError.invalidCode
        }

        isLoading = true
        defer { isLoading = false }

        let response = try await client.signIn(code: code, nonce: nonce)

        // Store tokens
        keychain.set(response.access_token, forKey: "access_token")
        keychain.set(response.refresh_token, forKey: "refresh_token")
        print("🔐 Tokens saved to keychain")

        // Get user info
        let user = try await client.getCurrentUser(accessToken: response.access_token)

        // Update state
        self.currentUser = user
        self.isAuthenticated = true

        // Sync with Convex
        await ConvexClientManager.shared.syncAuth()

        // Clear pending state
        pendingNonce = nil
        pendingEmail = nil
    }

    // MARK: - Password Sign In (Debug)

    func signInWithPassword(email: String, password: String) async throws {
        isLoading = true
        defer { isLoading = false }

        let response = try await client.signInWithPassword(email: email, password: password)

        // Store tokens
        keychain.set(response.access_token, forKey: "access_token")
        keychain.set(response.refresh_token, forKey: "refresh_token")
        print("🔐 Password login: Tokens saved")

        // Get user info
        let user = try await client.getCurrentUser(accessToken: response.access_token)
        print("🔐 Password login: Got user \(user.primary_email ?? "unknown")")

        // Update state
        self.currentUser = user
        self.isAuthenticated = true

        // Sync with Convex
        print("🔐 Password login: Syncing with Convex...")
        await ConvexClientManager.shared.syncAuth()
        print("🔐 Password login: Convex sync complete")
    }

    func signOut() async {
        if let refreshToken = keychain.get("refresh_token") {
            try? await client.signOut(refreshToken: refreshToken)
        }

        keychain.delete("access_token")
        keychain.delete("refresh_token")

        // Clear Convex auth
        await ConvexClientManager.shared.clearAuth()

        self.currentUser = nil
        self.isAuthenticated = false
    }

    // MARK: - Access Token

    func getAccessToken() async throws -> String {
        if let accessToken = keychain.get("access_token") {
            return accessToken
        }

        guard let refreshToken = keychain.get("refresh_token") else {
            throw AuthError.unauthorized
        }

        let newToken = try await client.refreshAccessToken(refreshToken: refreshToken)
        keychain.set(newToken, forKey: "access_token")
        return newToken
    }
}

// Token storage - uses UserDefaults in DEBUG (simulator-friendly), Keychain in production
class KeychainHelper {
    static let shared = KeychainHelper()
    private let service = "dev.cmux.app"

    private init() {}

    func set(_ value: String, forKey key: String) {
        #if DEBUG
        // UserDefaults persists across simulator reinstalls
        UserDefaults.standard.set(value, forKey: "auth_\(key)")
        print("🔐 Stored \(key) in UserDefaults (DEBUG)")
        #else
        let data = value.data(using: .utf8)!

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            SecItemAdd(addQuery as CFDictionary, nil)
        }
        #endif
    }

    func get(_ key: String) -> String? {
        #if DEBUG
        let value = UserDefaults.standard.string(forKey: "auth_\(key)")
        print("🔐 Reading \(key) from UserDefaults: \(value != nil)")
        return value
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
        #endif
    }

    func delete(_ key: String) {
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: "auth_\(key)")
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }
}
