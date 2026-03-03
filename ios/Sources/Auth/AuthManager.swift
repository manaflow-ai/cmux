import Foundation
import StackAuth
import SwiftUI

@MainActor
class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var isAuthenticated = false
    @Published var currentUser: StackAuthUser?
    @Published var isLoading = false
    @Published var isRestoringSession = false

    private let stack = StackAuthApp.shared

    private init() {
        primeSessionState()
        Task {
            await checkExistingSession()
        }
    }

    private var clearAuthRequested: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_CLEAR_AUTH"] == "1"
    }

    private var autoLoginCredentials: AuthAutoLoginCredentials? {
        AuthLaunchConfig.autoLoginCredentials(
            from: ProcessInfo.processInfo.environment,
            clearAuth: clearAuthRequested,
            mockDataEnabled: UITestConfig.mockDataEnabled
        )
    }

    // MARK: - Session Management

    private func primeSessionState() {
        if clearAuthRequested {
            clearAuthState()
            Task {
                await clearTokensForUITest()
            }
            isRestoringSession = false
            return
        }

        #if DEBUG
        if UITestConfig.mockDataEnabled {
            currentUser = StackAuthUser(
                id: "uitest_user",
                primaryEmail: "uitest@cmux.local",
                displayName: "UI Test"
            )
            isAuthenticated = true
            isRestoringSession = false
            return
        }

        if autoLoginCredentials != nil {
            if let cachedUser = AuthUserCache.shared.load() {
                currentUser = cachedUser
            }
            isAuthenticated = true
            isRestoringSession = false
            return
        }
        #endif

        if let cachedUser = AuthUserCache.shared.load() {
            currentUser = cachedUser
        }

        let hasTokens = AuthSessionCache.shared.hasTokens
        isAuthenticated = hasTokens || currentUser != nil
        isRestoringSession = false
    }

    private func checkExistingSession() async {
        if clearAuthRequested {
            return
        }

        #if DEBUG
        if UITestConfig.mockDataEnabled {
            return
        }

        if let credentials = autoLoginCredentials, !AuthSessionCache.shared.hasTokens {
            await performAutoLogin(credentials)
            return
        }
        #endif

        let cachedUser = AuthUserCache.shared.load()
        let hasCachedSession = AuthSessionCache.shared.hasTokens || cachedUser != nil
        let hasRefreshToken = await stack.getRefreshToken() != nil

        if hasCachedSession || hasRefreshToken {
            AuthSessionCache.shared.setHasTokens(true)
            if currentUser == nil, let cachedUser {
                currentUser = cachedUser
            }
            await validateCachedSession(hasRefreshToken: hasRefreshToken)
            return
        }

        if await stack.getAccessToken() != nil {
            AuthSessionCache.shared.setHasTokens(true)
            await validateCachedSession(hasRefreshToken: false)
            return
        }

        clearAuthState()
    }

    private func performAutoLogin(_ credentials: AuthAutoLoginCredentials) async {
        do {
            try await signInWithPassword(email: credentials.email, password: credentials.password, setLoading: false)
        } catch {
            print("🔐 Auto-login failed: \(error)")
            clearAuthState()
        }
    }

    private func validateCachedSession(hasRefreshToken: Bool) async {
        do {
            if let user = try await stack.getUser(or: .returnNull) {
                await applySignedInUser(user)
                return
            }
        } catch {
            print("🔐 Session validation failed: \(error)")
        }

        if hasRefreshToken || AuthSessionCache.shared.hasTokens || currentUser != nil {
            AuthSessionCache.shared.setHasTokens(true)
            isAuthenticated = true
            return
        }

        clearAuthState()
        await ConvexClientManager.shared.clearAuth()
    }

    private func applySignedInUser(_ user: CurrentUser) async {
        let mappedUser = await StackAuthUser(currentUser: user)
        currentUser = mappedUser
        isAuthenticated = true
        AuthUserCache.shared.save(mappedUser)
        AuthSessionCache.shared.setHasTokens(true)
        await ConvexClientManager.shared.syncAuth()
        await NotificationManager.shared.syncTokenIfPossible()
    }

    private func clearAuthState() {
        AuthUserCache.shared.clear()
        AuthSessionCache.shared.clear()
        currentUser = nil
        isAuthenticated = false
    }

    private func clearTokensForUITest() async {
        do {
            try await stack.signOut()
        } catch {
            print("🔐 Failed to clear Stack Auth tokens: \(error)")
        }
        await ConvexClientManager.shared.clearAuth()
    }

    // MARK: - Sign In Flow

    private var pendingNonce: String?

    func sendCode(to email: String) async throws {
        isLoading = true
        defer { isLoading = false }

        #if DEBUG
        if email == "42" {
            try await signInWithPassword(email: "l@l.com", password: "abc123", setLoading: false)
            return
        }
        #endif

        let callbackUrl = Environment.current == .development
            ? "http://localhost:3000/auth/callback"
            : "https://cmux.dev/auth/callback"

        let nonce = try await stack.sendMagicLinkEmail(email: email, callbackUrl: callbackUrl)
        pendingNonce = nonce
    }

    func verifyCode(_ code: String) async throws {
        guard let nonce = pendingNonce else {
            throw AuthError.invalidCode
        }

        isLoading = true
        defer { isLoading = false }

        let fullCode = AuthMagicLinkCode.compose(code: code, nonce: nonce)
        try await stack.signInWithMagicLink(code: fullCode)
        try await completeSignIn()

        pendingNonce = nil
    }

    // MARK: - Password Sign In (Debug)

    func signInWithPassword(email: String, password: String, setLoading: Bool = true) async throws {
        if setLoading {
            isLoading = true
        }
        defer {
            if setLoading {
                isLoading = false
            }
        }

        try await stack.signInWithCredential(email: email, password: password)
        try await completeSignIn()
    }

    // MARK: - Apple Sign In

    func signInWithApple() async throws {
        isLoading = true
        defer { isLoading = false }

        try await stack.signInWithOAuth(
            provider: "apple",
            presentationContextProvider: AuthPresentationContextProvider.shared
        )
        try await completeSignIn()
    }

    private func completeSignIn() async throws {
        guard let user = try await stack.getUser(or: .throw) else {
            throw AuthError.unauthorized
        }
        await applySignedInUser(user)
    }

    func signOut() async {
        do {
            try await stack.signOut()
        } catch {
            print("🔐 Sign-out failed: \(error)")
        }

        clearAuthState()
        await NotificationManager.shared.unregisterFromServer()
        await ConvexClientManager.shared.clearAuth()
    }

    // MARK: - Access Token

    func getAccessToken() async throws -> String {
        guard let accessToken = await stack.getAccessToken() else {
            throw AuthError.unauthorized
        }
        return accessToken
    }
}

struct AuthAutoLoginCredentials: Equatable {
    let email: String
    let password: String
}

enum AuthLaunchConfig {
    static func autoLoginCredentials(
        from environment: [String: String],
        clearAuth: Bool,
        mockDataEnabled: Bool
    ) -> AuthAutoLoginCredentials? {
        if clearAuth || mockDataEnabled {
            return nil
        }
        guard let email = environment["CMUX_UITEST_STACK_EMAIL"], !email.isEmpty else {
            return nil
        }
        guard let password = environment["CMUX_UITEST_STACK_PASSWORD"], !password.isEmpty else {
            return nil
        }
        return AuthAutoLoginCredentials(email: email, password: password)
    }
}

enum AuthMagicLinkCode {
    static func compose(code: String, nonce: String) -> String {
        code + nonce
    }
}

final class AuthSessionCache {
    static let shared = AuthSessionCache()

    private let key = "auth_has_tokens"

    private init() {}

    var hasTokens: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    func setHasTokens(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

final class AuthUserCache {
    static let shared = AuthUserCache()
    private let userKey = "auth_cached_user"

    private init() {}

    func save(_ user: StackAuthUser) {
        do {
            let data = try JSONEncoder().encode(user)
            UserDefaults.standard.set(data, forKey: userKey)
        } catch {
            print("🔐 Failed to cache user: \(error)")
        }
    }

    func load() -> StackAuthUser? {
        guard let data = UserDefaults.standard.data(forKey: userKey) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(StackAuthUser.self, from: data)
        } catch {
            print("🔐 Failed to load cached user: \(error)")
            return nil
        }
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: userKey)
    }
}
