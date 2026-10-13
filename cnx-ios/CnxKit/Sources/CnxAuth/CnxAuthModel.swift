#if os(iOS)
import AuthenticationServices
import CMUXAuthCore
import CmuxAuthRuntime
import CnxModel
import Foundation
import Observation
import OSLog
import StackAuth

private let authModelLog = Logger(subsystem: "dev.cmux.cnx", category: "auth")

/// The app's auth surface over the shared `AuthCoordinator` (Stack Auth:
/// Apple, Google, GitHub, email code). Views read observable state and call
/// the sign-in actions; nothing here touches UI.
@MainActor
@Observable
public final class CnxAuthModel {
    /// Sign-in method.
    public enum Provider: String, Sendable, Hashable, CaseIterable {
        case apple, google, github, email
    }

    /// The signed-in user as the UI shows it.
    public struct User: Sendable, Hashable {
        public let id: String
        public let name: String
        public let email: String?

        public var initials: String {
            let parts = name.split(separator: " ").prefix(2)
            let letters = parts.compactMap(\.first).map(String.init).joined()
            return letters.isEmpty ? "?" : letters.uppercased()
        }
    }

    @ObservationIgnored let coordinator: AuthCoordinator?
    @ObservationIgnored let stack: StackClientApp?
    /// The `cnx-ios-api` base URL (`CNX_API_BASE`), when configured.
    @ObservationIgnored let apiBase: URL?
    /// Mock mode (DEBUG `CNX_MOCK_AUTH=1`): signed in as a local user, no network.
    public let isMock: Bool
    private var mockSignedIn: Bool

    /// The provider whose flow is in flight (its button shows a spinner).
    public private(set) var busyProvider: Provider?
    /// A display-safe error for the welcome screen, `nil` on cancel.
    public var errorMessage: String?

    init(coordinator: AuthCoordinator?, stack: StackClientApp? = nil, apiBase: URL? = nil, isMock: Bool) {
        self.coordinator = coordinator
        self.stack = stack
        self.apiBase = apiBase
        self.isMock = isMock
        self.mockSignedIn = isMock
    }

    /// Builds the live model for this process. Non-DEBUG builds (Release,
    /// Production) use the production Stack project and its
    /// `https://cmux.com/auth/callback`, and never read launch overrides.
    /// Reads launch overrides from the environment (DEBUG only): `CNX_CLEAR_AUTH=1` starts signed out,
    /// `CNX_MOCK_AUTH=1` (or Settings → Developer → Mock data) signs in a
    /// local mock user, and
    /// `CNX_STACK_EMAIL` / `CNX_STACK_PASSWORD` auto-login a Stack test account.
    public static func live(environment: [String: String], bundleIdentifier: String?) -> CnxAuthModel {
        #if DEBUG
        let isDebug = true
        if environment["CNX_MOCK_AUTH"] == "1" || DeveloperOptions.mockData {
            let model = CnxAuthModel(coordinator: nil, isMock: true)
            model.mockSignedIn = environment["CNX_CLEAR_AUTH"] != "1"
            return model
        }
        #else
        let isDebug = false
        #endif
        var launchEnvironment: [String: String] = [:]
        if isDebug, let email = environment["CNX_STACK_EMAIL"], let password = environment["CNX_STACK_PASSWORD"] {
            launchEnvironment["CMUX_UITEST_STACK_EMAIL"] = email
            launchEnvironment["CMUX_UITEST_STACK_PASSWORD"] = password
        }
        let config = AuthConfig(environment: isDebug ? .development : .production)
        let tokenStore = KeychainStackTokenStore(
            service: KeychainStackTokenStore.serviceName(bundleIdentifier: bundleIdentifier),
            legacyProjectID: config.stack.projectId
        )
        // Built over StackClientApp directly so team creation goes to Stack
        // (the cmux web API base is a localhost dev server in DEBUG).
        let stack = StackClientApp(
            projectId: config.stack.projectId,
            publishableClientKey: config.stack.publishableClientKey,
            tokenStore: .custom(tokenStore),
            oauthBrowserSessionPrivacy: .shared
        )
        let defaults = UserDefaults.standard
        let coordinator = AuthCoordinator(
            client: StackAuthClient(stack: stack),
            sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "cnx.auth.hasTokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "cnx.auth.cachedUser"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "cnx.auth.selectedTeam"),
            anchor: AuthPresentationContextProvider(),
            config: config,
            launch: AuthLaunchOptions(
                clearAuthRequested: isDebug && environment["CNX_CLEAR_AUTH"] == "1",
                mockDataEnabled: false,
                environment: launchEnvironment,
                includesDevAuth: isDebug
            )
        )
        coordinator.start()
        let apiBase = Self.apiBase(environment: isDebug ? environment : [:], infoValue: Bundle.main.object(forInfoDictionaryKey: "CNXAPIBase") as? String, isDebug: isDebug)
        // Which backend this build talks to (public ids only, no tokens).
        authModelLog.info("Stack project \(config.stack.projectId, privacy: .public) (\(isDebug ? "development" : "production", privacy: .public)), callback \(config.magicLinkCallbackURL, privacy: .public), service \(apiBase?.host() ?? "none", privacy: .public)")
        return CnxAuthModel(coordinator: coordinator, stack: stack, apiBase: apiBase, isMock: false)
    }

    /// The `cnx-ios-api` base URL: the `CNX_API_BASE` launch override (DEBUG
    /// only), else the build's `CNXAPIBase` Info.plist value (set by the
    /// Production configuration), else the dev Worker in DEBUG builds.
    static func apiBase(environment: [String: String], infoValue: String?, isDebug: Bool) -> URL? {
        if let override = environment["CNX_API_BASE"], let url = URL(string: override) { return url }
        if let infoValue, !infoValue.isEmpty, let url = URL(string: infoValue) { return url }
        return isDebug ? URL(string: "https://cnx-ios-api-dev.debussy.workers.dev") : nil
    }

    /// Whether launch auth has resolved (a cached session counts immediately).
    public var isResolved: Bool {
        guard let coordinator else { return true }
        return coordinator.isAuthenticated || !coordinator.isRestoringSession
    }

    public var isSignedIn: Bool {
        coordinator?.isAuthenticated ?? mockSignedIn
    }

    public var user: User? {
        if isMock { return mockSignedIn ? User(id: "mock", name: "Aziz Albahar", email: "aziz@example.com") : nil }
        guard let user = coordinator?.currentUser else { return nil }
        let name = user.displayName?.isEmpty == false ? user.displayName! : (user.primaryEmail ?? "cmux user")
        return User(id: user.id, name: name, email: user.primaryEmail)
    }

    /// Stack teams for the signed-in account (empty in mock mode).
    public var teams: [AppStore.AccountTeam] {
        coordinator?.availableTeams.map { AppStore.AccountTeam(id: $0.id, name: $0.displayName) } ?? []
    }

    public var selectedTeamID: String? { coordinator?.resolvedTeamID }

    /// Whether interactive work disables the other sign-in buttons.
    public var isBusy: Bool { busyProvider != nil }

    /// Runs an OAuth provider flow. Cancel is silent; failures set `errorMessage`.
    public func signIn(with provider: Provider) async -> Bool {
        guard busyProvider == nil else { return false }
        busyProvider = provider
        errorMessage = nil
        defer { busyProvider = nil }
        if isMock {
            mockSignedIn = true
            return true
        }
        guard let coordinator else { return false }
        do {
            switch provider {
            case .apple: try await coordinator.signInWithApple()
            case .google: try await coordinator.signInWithGoogle()
            case .github: try await coordinator.signInWithGitHub()
            case .email: return false
            }
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    /// Sends a 6-digit code to `email`.
    public func sendCode(to email: String) async throws {
        if isMock { return }
        try await coordinator?.sendCode(to: email)
    }

    /// Verifies the 6-digit code; on success the session is live.
    public func verifyCode(_ code: String) async throws {
        if isMock {
            guard code == "424242" else { throw AuthError.invalidCode }
            mockSignedIn = true
            return
        }
        try await coordinator?.verifyCode(code)
    }

    /// Persists a team selection on Stack (cross-device). Best effort.
    public func selectTeam(_ id: String) async {
        try? await coordinator?.selectTeam(id: id)
    }

    /// Creates a team and selects it.
    public func createTeam(named name: String) async throws -> AppStore.AccountTeam {
        if isMock { return AppStore.AccountTeam(id: "team-\(UUID().uuidString.prefix(8))", name: name) }
        guard let coordinator else { throw AuthError.unauthorized }
        let team = try await coordinator.createTeam(displayName: name)
        return AppStore.AccountTeam(id: team.id, name: team.displayName)
    }

    /// Joins a team from a Stack invitation link (`...?code=...`) and refreshes
    /// the team list.
    public func joinTeam(inviteLink: String) async throws {
        let trimmed = inviteLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = URLComponents(string: trimmed)?.queryItems?.first { $0.name == "code" }?.value ?? trimmed
        guard !code.isEmpty else { throw AuthError.invalidCode }
        if isMock { return }
        guard let stack, let coordinator else { throw AuthError.unauthorized }
        try await stack.acceptTeamInvitation(code: code)
        await coordinator.refreshTeams()
    }

    /// Errors from invite-link creation.
    public enum InviteError: Error, Sendable {
        /// No `cnx-ios-api` base URL is configured in this build.
        case serviceUnavailable
        case requestFailed
    }

    /// A Stack invitation URL for `teamID` from `POST /v1/teams/:teamId/invites`.
    public func inviteLink(teamID: String) async throws -> URL {
        guard let apiBase, let coordinator else { throw InviteError.serviceUnavailable }
        let tokens = try await coordinator.currentTokens()
        var request = URLRequest(url: apiBase.appending(path: "v1/teams/\(teamID)/invites"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let string = object["url"] as? String, let url = URL(string: string) else {
            throw InviteError.requestFailed
        }
        return url
    }

    /// The `cnx-ios-api` base URL for live data (nil in mock mode or when unconfigured).
    public var apiBaseURL: URL? { isMock ? nil : apiBase }

    /// A current Stack access token (refreshed by the runtime when needed).
    /// `forceRefresh` mints a new one after the service rejected the last (401).
    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let coordinator else { throw AuthError.unauthorized }
        return forceRefresh ? try await coordinator.forceRefreshAccessToken() : try await coordinator.accessToken()
    }

    /// Local-first sign-out.
    public func signOut() async {
        if isMock {
            mockSignedIn = false
            return
        }
        await coordinator?.signOut()
    }

    /// A user-facing message for an auth error, or `nil` for a user cancel.
    public static func message(for error: any Error) -> String? {
        if let error = error as? ASAuthorizationError, error.code == .canceled { return nil }
        if let authError = AuthError(displaySafe: error) {
            if authError == .cancelled { return nil }
            return authError.errorDescription
        }
        if error is CancellationError { return nil }
        return "Something went wrong. Try again."
    }
}
#endif
