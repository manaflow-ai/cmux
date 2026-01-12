import Foundation
import SwiftUI

@MainActor
class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var isAuthenticated = false
    @Published var currentUser: StackAuthClient.User?
    @Published var isLoading = false
    @Published var isRestoringSession = false

    private let client = StackAuthClient.shared
    private let keychain = KeychainHelper.shared

    private init() {
        // Check for existing session on launch
        primeSessionState()
        Task {
            await checkExistingSession()
        }
    }

    // MARK: - Session Management

    private func primeSessionState() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UITEST_CLEAR_AUTH"] == "1" {
            keychain.delete("access_token")
            keychain.delete("refresh_token")
            AuthUserCache.shared.clear()
            print("🔐 Cleared auth for UI test launch")
        }
        #endif

        let hasRefresh = keychain.get("refresh_token")
        let hasAccess = keychain.get("access_token")
        let hasAnyToken = hasRefresh != nil || hasAccess != nil

        if let cachedUser = AuthUserCache.shared.load() {
            self.currentUser = cachedUser
        }

        if hasAnyToken {
            self.isAuthenticated = true
        } else {
            self.currentUser = nil
            self.isAuthenticated = false
        }
        self.isRestoringSession = false
    }

    private func checkExistingSession() async {
        let hasRefresh = keychain.get("refresh_token")
        let hasAccess = keychain.get("access_token")
        print("🔐 Checking session - refresh: \(hasRefresh != nil), access: \(hasAccess != nil)")

        if hasRefresh == nil && hasAccess == nil {
            print("🔐 No cached tokens, showing sign-in immediately")
            self.currentUser = nil
            self.isAuthenticated = false
            return
        }

        if let accessToken = hasAccess, let remaining = accessTokenTimeRemaining(accessToken), remaining > 30 {
            if let cachedUser = AuthUserCache.shared.load() {
                self.currentUser = cachedUser
                print("🔐 Loaded cached user for optimistic restore")
            }
            self.isAuthenticated = true
            print("🔐 Optimistically restored session from access token")
            Task {
                if self.currentUser == nil || remaining < 300 {
                    await validateCachedSession(accessToken: accessToken, refreshToken: hasRefresh)
                } else {
                    await ConvexClientManager.shared.syncAuth()
                }
            }
            return
        }

        guard let refreshToken = hasRefresh else {
            print("🔐 No refresh token found in keychain, clearing auth state")
            // Clear expired access token and auth state since we can't refresh
            keychain.delete("access_token")
            AuthUserCache.shared.clear()
            self.currentUser = nil
            self.isAuthenticated = false
            return
        }

        if let cachedUser = AuthUserCache.shared.load() {
            self.currentUser = cachedUser
            print("🔐 Loaded cached user for optimistic restore (refresh-only)")
        }
        self.isAuthenticated = true
        Task {
            await validateCachedSession(accessToken: hasAccess, refreshToken: refreshToken)
        }
    }

    private func validateCachedSession(accessToken: String?, refreshToken: String?) async {
        if let accessToken {
            do {
                let user = try await client.getCurrentUser(accessToken: accessToken)
                self.currentUser = user
                self.isAuthenticated = true
                AuthUserCache.shared.save(user)
                print("🔐 Session validated for \(user.primary_email ?? "unknown")")
                await ConvexClientManager.shared.syncAuth()
                return
            } catch {
                print("🔐 Access token validation failed: \(error)")
            }
        }

        guard let refreshToken else {
            print("🔐 No refresh token available after access token failure")
            AuthUserCache.shared.clear()
            self.currentUser = nil
            self.isAuthenticated = false
            return
        }

        do {
            let newAccessToken = try await client.refreshAccessToken(refreshToken: refreshToken)
            keychain.set(newAccessToken, forKey: "access_token")

            let user = try await client.getCurrentUser(accessToken: newAccessToken)
            self.currentUser = user
            self.isAuthenticated = true
            AuthUserCache.shared.save(user)
            print("🔐 Session refreshed for \(user.primary_email ?? "unknown")")
            await ConvexClientManager.shared.syncAuth()
        } catch {
            print("🔐 Session refresh failed: \(error)")
            if let authError = error as? AuthError, case .unauthorized = authError {
                keychain.delete("refresh_token")
                keychain.delete("access_token")
                AuthUserCache.shared.clear()
                self.currentUser = nil
                self.isAuthenticated = false
            }
        }
    }

    private func accessTokenTimeRemaining(_ token: String) -> TimeInterval? {
        guard let payload = decodeJWTPayload(from: token), let exp = payload.exp else {
            return nil
        }
        let expirationDate = Date(timeIntervalSince1970: TimeInterval(exp))
        return expirationDate.timeIntervalSinceNow
    }

    private struct JWTPayload: Decodable {
        let exp: Int?
        let sub: String?
        let email: String?
    }

    private func decodeJWTPayload(from token: String) -> JWTPayload? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payloadPart = String(parts[1])
        let padded = padBase64Url(payloadPart)
        guard let data = Data(base64Encoded: padded) else { return nil }
        return try? JSONDecoder().decode(JWTPayload.self, from: data)
    }

    private func padBase64Url(_ value: String) -> String {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return base64
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
        AuthUserCache.shared.save(user)

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
        AuthUserCache.shared.save(user)

        // Sync with Convex
        print("🔐 Password login: Syncing with Convex...")
        await ConvexClientManager.shared.syncAuth()
        print("🔐 Password login: Convex sync complete")
    }

    func signOut() async {
        let refreshToken = keychain.get("refresh_token")
        self.isAuthenticated = false

        keychain.delete("access_token")
        keychain.delete("refresh_token")
        AuthUserCache.shared.clear()

        // Clear Convex auth
        await ConvexClientManager.shared.clearAuth()

        if let refreshToken {
            try? await client.signOut(refreshToken: refreshToken)
        }

        self.currentUser = nil
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

class AuthUserCache {
    static let shared = AuthUserCache()
    private let userKey = "auth_cached_user"

    private init() {}

    func save(_ user: StackAuthClient.User) {
        do {
            let data = try JSONEncoder().encode(user)
            UserDefaults.standard.set(data, forKey: userKey)
        } catch {
            print("🔐 Failed to cache user: \(error)")
        }
    }

    func load() -> StackAuthClient.User? {
        guard let data = UserDefaults.standard.data(forKey: userKey) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(StackAuthClient.User.self, from: data)
        } catch {
            print("🔐 Failed to load cached user: \(error)")
            return nil
        }
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: userKey)
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
