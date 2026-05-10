import CMUXAuthCore
import Foundation
import Observation
import OSLog
import StackAuth

private let authLog = Logger(subsystem: "ai.manaflow.cmux.ios", category: "auth")

@MainActor
@Observable
final class AuthManager {
    static let shared = AuthManager()

    var isAuthenticated = false
    var currentUser: StackAuthUser?
    var isLoading = false
    var isRestoringSession = false

    private let stack = StackAuthApp.shared
    private let authUserCache = AuthUserCache.shared
    private let authSessionCache = AuthSessionCache.shared
    private var pendingNonce: String?

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

    private var authFixtureUser: StackAuthUser? {
        AuthLaunchConfig.fixtureUser(
            from: ProcessInfo.processInfo.environment,
            clearAuth: clearAuthRequested,
            mockDataEnabled: UITestConfig.mockDataEnabled
        )
    }

    private func primeSessionState() {
        if clearAuthRequested {
            clearAuthState()
            Task {
                await clearPersistedAuthForUITest()
            }
            return
        }

        #if DEBUG
        if UITestConfig.mockDataEnabled {
            applyAuthState(
                CMUXAuthState.primed(
                    clearAuthRequested: false,
                    mockDataEnabled: true,
                    fixtureUser: nil,
                    autoLoginCredentials: nil,
                    cachedUser: nil,
                    hasTokens: false,
                    mockUser: uiTestMockUser
                )
            )
            return
        }

        if let authFixtureUser {
            authLog.debug("Using auth fixture user")
            applyAuthState(
                CMUXAuthState.primed(
                    clearAuthRequested: false,
                    mockDataEnabled: false,
                    fixtureUser: authFixtureUser,
                    autoLoginCredentials: nil,
                    cachedUser: authFixtureUser,
                    hasTokens: true,
                    mockUser: uiTestMockUser
                )
            )
            return
        }

        if autoLoginCredentials != nil {
            authLog.debug("Auto-login credentials detected")
            applyAuthState(
                CMUXAuthState.primed(
                    clearAuthRequested: false,
                    mockDataEnabled: false,
                    fixtureUser: nil,
                    autoLoginCredentials: autoLoginCredentials,
                    cachedUser: authUserCache.load(),
                    hasTokens: authSessionCache.hasTokens,
                    mockUser: uiTestMockUser
                )
            )
            return
        }
        #endif

        applyAuthState(
            CMUXAuthState.primed(
                clearAuthRequested: false,
                mockDataEnabled: false,
                fixtureUser: nil,
                autoLoginCredentials: nil,
                cachedUser: authUserCache.load(),
                hasTokens: authSessionCache.hasTokens,
                mockUser: uiTestMockUser
            )
        )
    }

    private func checkExistingSession() async {
        if clearAuthRequested {
            return
        }

        #if DEBUG
        if UITestConfig.mockDataEnabled {
            return
        }

        if let fixtureUser = authFixtureUser {
            authLog.debug("Applying auth fixture user")
            authUserCache.save(fixtureUser)
            authSessionCache.setHasTokens(true)
            currentUser = fixtureUser
            isAuthenticated = true
            return
        }

        if DebugShortcutSession.isPersisted, let cachedUser = authUserCache.load() {
            authLog.debug("Restoring local debug auth shortcut")
            authSessionCache.setHasTokens(true)
            currentUser = cachedUser
            isAuthenticated = true
            return
        }

        if let credentials = autoLoginCredentials, !authSessionCache.hasTokens {
            authLog.debug("Starting auto-login for \(credentials.email, privacy: .private)")
            await performAutoLogin(credentials)
            return
        }
        #endif

        let cachedUser = authUserCache.load()
        let hasAccessToken = await stack.getAccessToken() != nil
        let hasRefreshToken = await stack.getRefreshToken() != nil
        let hasStoredTokens = hasAccessToken || hasRefreshToken

        if hasStoredTokens {
            authSessionCache.setHasTokens(true)
            if currentUser == nil, let cachedUser {
                currentUser = cachedUser
            }
            await validateCachedSession(hasStoredTokens: hasStoredTokens)
            return
        }

        #if DEBUG
        if let creds = debugPasswordCredentials {
            authLog.debug("Auto-login with persisted debug credentials")
            await performAutoLogin(AuthAutoLoginCredentials(email: creds.email, password: creds.password))
            return
        }
        #endif

        clearAuthState()
    }

    private func performAutoLogin(_ credentials: AuthAutoLoginCredentials) async {
        do {
            try await signInWithPassword(email: credentials.email, password: credentials.password, setLoading: false)
        } catch {
            authLog.error("Auto-login failed: \(error.localizedDescription, privacy: .public)")
            clearAuthState()
        }
    }

    private func validateCachedSession(hasStoredTokens: Bool) async {
        do {
            if let user = try await stack.getUser(or: .returnNull) {
                await applySignedInUser(user)
                return
            }
            authLog.info("Cached session validation returned no current user")
            clearAuthState()
            return
        } catch {
            authLog.error("Session validation failed: \(error.localizedDescription, privacy: .public)")
        }

        if hasStoredTokens {
            authSessionCache.setHasTokens(true)
            isAuthenticated = true
            return
        }

        clearAuthState()
    }

    private func applySignedInUser(_ user: CurrentUser) async {
        let mappedUser = await StackAuthUser(currentUser: user)
        await applySignedInUser(mappedUser)
    }

    private func applySignedInUser(_ mappedUser: StackAuthUser) async {
        currentUser = mappedUser
        isAuthenticated = true
        authUserCache.save(mappedUser)
        authSessionCache.setHasTokens(true)
        await NotificationManager.shared.syncTokenIfPossible()
    }

    private func clearAuthState() {
        #if DEBUG
        DebugShortcutSession.clear()
        #endif
        authUserCache.clear()
        authSessionCache.clear()
        applyAuthState(.cleared())
    }

    private func clearPersistedAuthForUITest() async {
        // UI tests only need deterministic local signed-out state at launch.
    }

    #if DEBUG
    private struct DebugCredentials {
        let email: String
        let password: String

        func persist() {
            UserDefaults.standard.set(email, forKey: "cmux.debug.auth.email")
            UserDefaults.standard.set(password, forKey: "cmux.debug.auth.password")
        }

        static func load() -> DebugCredentials? {
            guard let email = UserDefaults.standard.string(forKey: "cmux.debug.auth.email"),
                  let password = UserDefaults.standard.string(forKey: "cmux.debug.auth.password"),
                  !email.isEmpty, !password.isEmpty else { return nil }
            return DebugCredentials(email: email, password: password)
        }
    }

    private var debugPasswordCredentials: DebugCredentials? = DebugCredentials.load()
    #endif

    func sendCode(to email: String) async throws {
        isLoading = true
        defer { isLoading = false }

        #if DEBUG
        if email.trimmingCharacters(in: .whitespacesAndNewlines) == "42" {
            DebugShortcutSession.persist()
            await applySignedInUser(debugShortcutUser)
            return
        }
        #endif

        let callbackUrl = AppEnvironment.current == .development
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

    func signInWithApple() async throws {
        isLoading = true
        defer { isLoading = false }

        try await stack.signInWithOAuth(
            provider: "apple",
            presentationContextProvider: AuthPresentationContextProvider.shared
        )
        try await completeSignIn()
    }

    func signInWithGoogle() async throws {
        isLoading = true
        defer { isLoading = false }

        try await stack.signInWithOAuth(
            provider: "google",
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
            authLog.error("Sign-out failed: \(error.localizedDescription, privacy: .public)")
        }

        clearAuthState()
        await NotificationManager.shared.unregisterFromServer()
    }

    func getAccessToken() async throws -> String {
        if let accessToken = await stack.getAccessToken() {
            return accessToken
        }

        #if DEBUG
        if DebugShortcutSession.isPersisted, isAuthenticated {
            return "debug-42-access-token"
        }

        if let credentials = debugPasswordCredentials {
            try? await signInWithPassword(
                email: credentials.email,
                password: credentials.password,
                setLoading: false
            )
            if let accessToken = await stack.getAccessToken() {
                return accessToken
            }
        }
        #endif

        throw AuthError.unauthorized
    }
}

private extension AuthManager {
    var uiTestMockUser: StackAuthUser {
        StackAuthUser(
            id: "uitest_user",
            primaryEmail: "uitest@cmux.local",
            displayName: "UI Test"
        )
    }

    #if DEBUG
    var debugShortcutUser: StackAuthUser {
        StackAuthUser(
            id: "debug_42",
            primaryEmail: "42@cmux.local",
            displayName: "Debug 42"
        )
    }
    #endif

    func applyAuthState(_ state: CMUXAuthState) {
        currentUser = state.currentUser
        isAuthenticated = state.isAuthenticated
        isRestoringSession = state.isRestoringSession
    }
}

typealias AuthAutoLoginCredentials = CMUXAuthAutoLoginCredentials

enum AuthLaunchConfig {
    static func autoLoginCredentials(
        from environment: [String: String],
        clearAuth: Bool,
        mockDataEnabled: Bool
    ) -> AuthAutoLoginCredentials? {
        CMUXAuthLaunchConfig.autoLoginCredentials(
            from: environment,
            clearAuth: clearAuth,
            mockDataEnabled: mockDataEnabled
        )
    }

    static func fixtureUser(
        from environment: [String: String],
        clearAuth: Bool,
        mockDataEnabled: Bool
    ) -> StackAuthUser? {
        CMUXAuthLaunchConfig.fixtureUser(
            from: environment,
            clearAuth: clearAuth,
            mockDataEnabled: mockDataEnabled
        ).map { StackAuthUser(id: $0.id, primaryEmail: $0.primaryEmail, displayName: $0.displayName) }
    }
}

enum AuthMagicLinkCode {
    static func compose(code: String, nonce: String) -> String {
        CMUXAuthMagicLinkCode.compose(code: code, nonce: nonce)
    }
}

#if DEBUG
private enum DebugShortcutSession {
    private static let key = "cmux.debug.auth.local42"

    static var isPersisted: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func persist() {
        UserDefaults.standard.set(true, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
#endif

@MainActor
final class AuthSessionCache {
    static let shared = AuthSessionCache()
    private let cache = CMUXAuthSessionCache(
        keyValueStore: UserDefaults.standard,
        key: "auth_has_tokens"
    )

    private init() {}

    var hasTokens: Bool {
        cache.hasTokens
    }

    func setHasTokens(_ value: Bool) {
        cache.setHasTokens(value)
    }

    func clear() {
        cache.clear()
    }
}

@MainActor
final class AuthUserCache {
    static let shared = AuthUserCache()
    private let store = CMUXAuthIdentityStore(
        keyValueStore: UserDefaults.standard,
        key: "auth_cached_user"
    )

    private init() {}

    func save(_ user: StackAuthUser) {
        do {
            try store.save(user)
        } catch {
            authLog.error("Failed to cache user: \(error.localizedDescription, privacy: .public)")
        }
    }

    func load() -> StackAuthUser? {
        do {
            return try store.load()
        } catch {
            authLog.error("Failed to load cached user: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func clear() {
        store.clear()
    }
}
