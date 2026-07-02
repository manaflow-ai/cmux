import CMUXAuthCore
import CmuxAuthRuntime
import CmuxMobileSupport
import CmuxMobileTransport
import Foundation
import StackAuth

/// The auth composition root for the iOS app.
///
/// Constructs the de-singletonized auth graph once at app startup: resolves
/// ``CmuxAuthRuntime/AuthConfig`` from the environment + an injected
/// `LocalConfig.plist` override table, builds the ``CmuxAuthRuntime/AuthCoordinator``
/// (with a `StackAuthClient`, persistence caches over an injected `UserDefaults`,
/// and an ``CmuxAuthRuntime/AuthPresentationContextProvider``), and the
/// ``CmuxAuthRuntime/PushRegistrationService``. Replaces `AuthManager.shared`,
/// `StackAuthApp.shared`, `AuthPresentationContextProvider.shared`,
/// `AuthSessionCache.shared`, `AuthUserCache.shared`, and the `AppEnvironment`
/// secret/URL tables.
@MainActor
public struct MobileAuthComposition {
    /// The shared auth orchestrator the UI binds to.
    public let coordinator: AuthCoordinator
    /// The push registration service (off by default).
    public let pushRegistration: PushRegistrationService
    /// The resolved configuration (used for diagnostics + push API base URL).
    public let config: AuthConfig
    /// Which Stack project this build signs in to. DEBUG defaults to
    /// development and Release to production, but an ``authEnvironmentOverrideKey``
    /// entry (from `LocalConfig.plist`, or the Info.plist value
    /// `ios/scripts/reload.sh --prod-auth` bakes) flips it, so a sideloaded
    /// dev build can run production auth and pair with a release Mac
    /// (https://github.com/manaflow-ai/cmux/issues/7145). Exposed so the
    /// identity provider can label the channel its user ids belong to.
    public let authEnvironment: CMUXAuthEnvironment

    /// A reachability monitor used to fail sign-in flows fast when offline.
    private let reachability: any ReachabilityProviding

    /// Build the auth graph.
    ///
    /// - Parameters:
    ///   - environment: The process environment (UI-test fixtures/credentials).
    ///   - bundle: The bundle to read `LocalConfig.plist` overrides + bundle id
    ///     from. Defaults to `.main`; injected here so the *type* never reaches
    ///     for `Bundle.main` internally.
    ///   - defaults: Persistence for the session/user caches and push opt-in.
    ///   - reachability: Connectivity probe for fail-fast sign-in.
    ///   - policy: The build-flag policy (dev-auth `42` shortcut).
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        reachability: any ReachabilityProviding,
        policy: MobileAuthBuildPolicy = .current
    ) {
        self.reachability = reachability

        let overrides = Self.authOverrides(
            localConfig: Self.localConfigStringOverrides(in: bundle),
            bakedAuthEnvironment: bundle.object(forInfoDictionaryKey: Self.authEnvironmentInfoPlistKey) as? String
        )
        let resolvedEnvironment = Self.resolvedAuthEnvironment(
            isDevelopmentBuild: Self.isDevelopmentBuild,
            overrides: overrides
        )
        self.authEnvironment = resolvedEnvironment
        let resolvedConfig = AuthConfig(
            environment: resolvedEnvironment,
            overrides: overrides
        )
        self.config = resolvedConfig

        let client = StackAuthClient(
            config: resolvedConfig,
            tokenStore: Self.tokenStore
        )
        let sessionCache = CMUXAuthSessionCache(
            keyValueStore: defaults,
            key: Self.sessionCacheDefaultsKey
        )
        let userCache = CMUXAuthIdentityStore(
            keyValueStore: defaults,
            key: Self.cachedUserDefaultsKey
        )
        let teamSelection = CMUXAuthTeamSelectionStore(
            keyValueStore: defaults,
            key: "auth_selected_team"
        )
        // Switching the resolved Stack project on one install (a dev build
        // rebuilt with --prod-auth, or back — or a STACK_PROJECT_ID_* override
        // changing within the same environment) must not restore the previous
        // project's session: tokens, user ids, and teams are per-project, so
        // the stale state could only fail validation and flash the wrong
        // cached user. This rides its own launch flag (NOT clearAuthRequested,
        // whose UI-test semantics stop priming and would suppress the dogfood
        // auto-login on the very next normal reload).
        let authProjectSwitched = Self.detectAuthProjectSwitch(
            resolvedProjectID: resolvedConfig.stack.projectId,
            buildDefaultProjectID: AuthConfig(
                environment: Self.isDevelopmentBuild ? .development : .production,
                overrides: overrides
            ).stack.projectId,
            defaults: defaults
        )
        let launch = AuthLaunchOptions(
            clearAuthRequested: environment["CMUX_UITEST_CLEAR_AUTH"] == "1",
            mockDataEnabled: UITestConfig.mockDataEnabled,
            environment: environment,
            includesDevAuth: policy.includesFortyTwoShortcut,
            clearStaleAuthOnLaunch: authProjectSwitched
        )
        // Break the coordinator <-> push cycle: the coordinator is built first
        // and reaches the push service (for its post-sign-in token re-upload)
        // through a deferred async hook that is pointed at the push service once
        // it exists. The push service reads tokens directly from the coordinator.
        let deferredSignIn = DeferredSignInHook()
        let monitor = reachability
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: sessionCache,
            userCache: userCache,
            teamSelection: teamSelection,
            anchor: AuthPresentationContextProvider(),
            config: resolvedConfig,
            launch: launch,
            isOnline: { await monitor.isOnline },
            onSignedIn: { await deferredSignIn.run() }
        )
        let push = PushRegistrationService(
            tokenProvider: coordinator,
            apiBaseURL: resolvedConfig.apiBaseURL,
            bundleID: bundle.bundleIdentifier ?? "",
            apnsEnvironment: Self.apnsEnvironment,
            session: .shared
        )
        deferredSignIn.set { await push.syncTokenIfPossible() }
        self.coordinator = coordinator
        self.pushRegistration = push
    }

    /// Begin asynchronous session restore (call once after construction).
    public func start() {
        coordinator.start()
    }

    private static var isDevelopmentBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The override-table key selecting the auth environment. Values
    /// `"production"` / `"development"` (case-insensitive); anything else keeps
    /// the build default. Sourced from `LocalConfig.plist` or the Info.plist
    /// bake (see ``authEnvironmentInfoPlistKey``).
    nonisolated static let authEnvironmentOverrideKey = "AuthEnvironment"

    /// The Info.plist key carrying the baked auth environment. A tapped device
    /// build sees no shell env, so `ios/scripts/reload.sh --prod-auth` bakes
    /// the channel into the build via the `CMUX_IOS_AUTH_ENV` build setting —
    /// the same mechanism as `CMUXPresenceBaseURL`. Keep in sync with
    /// `ios/Config/Info.plist` and `ios/Config/Shared.xcconfig`.
    nonisolated static let authEnvironmentInfoPlistKey = "CMUXAuthEnvironment"

    /// Merge the Info.plist-baked auth environment into the `LocalConfig.plist`
    /// override table. An explicit LocalConfig entry wins over the bake
    /// (mirroring presence resolution, where the local override table beats the
    /// baked Info.plist value); blank baked values are ignored so the empty
    /// `$(CMUX_IOS_AUTH_ENV)` expansion in a normal build contributes nothing.
    nonisolated static func authOverrides(
        localConfig: [String: String],
        bakedAuthEnvironment: String?
    ) -> [String: String] {
        var overrides = localConfig
        if overrides[authEnvironmentOverrideKey] == nil,
           let baked = bakedAuthEnvironment?.trimmingCharacters(in: .whitespacesAndNewlines),
           !baked.isEmpty {
            overrides[authEnvironmentOverrideKey] = baked
        }
        return overrides
    }

    /// Resolve which Stack project this build signs in to: an explicit
    /// ``authEnvironmentOverrideKey`` override wins; otherwise DEBUG builds
    /// default to development and Release builds to production. Unrecognized
    /// values keep the build default (fail toward the channel the build was
    /// compiled for).
    nonisolated static func resolvedAuthEnvironment(
        isDevelopmentBuild: Bool,
        overrides: [String: String]
    ) -> CMUXAuthEnvironment {
        switch overrides[authEnvironmentOverrideKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "production":
            return .production
        case "development":
            return .development
        default:
            return isDevelopmentBuild ? .development : .production
        }
    }

    /// The defaults key persisting which Stack project id this install last
    /// launched with, so a project switch is detectable. The PROJECT ID, not
    /// the environment name: `STACK_PROJECT_ID_DEV/PROD` overrides can change
    /// the actual project while the environment label stays constant, and the
    /// per-project session state is what goes stale.
    nonisolated static let storedStackProjectIDKey = "auth_stack_project_id"

    /// The session cache defaults key (whether Stack tokens are persisted).
    nonisolated static let sessionCacheDefaultsKey = "auth_has_tokens"

    /// The cached-identity defaults key (the last signed-in user snapshot).
    nonisolated static let cachedUserDefaultsKey = "auth_cached_user"

    /// Persist `resolvedProjectID` and report whether the resolved Stack
    /// project changed since the last launch, requiring the stale local auth
    /// state to be cleared.
    ///
    /// Installs that predate the override plumbing never stored the key, but
    /// any session they hold can only belong to `buildDefaultProjectID` (the
    /// project the build-default environment resolves to under the same
    /// override table) — so a missing value is inferred as that default.
    /// Ordinary upgrades and plain first launches (resolved == build
    /// default) therefore never clear, while the FIRST `--prod-auth` launch
    /// over a signed-in dev install correctly does (its cached dev-project
    /// identity must not prime under production auth). A recorded or
    /// inferred project change ALWAYS clears — deliberately not gated on the
    /// defaults caches being non-empty, because the Stack token store is
    /// keychain-backed and project-scoped: tokens for the target project can
    /// outlive empty defaults (a signed-out interlude on another channel, or
    /// a reinstall), and returning to that project must start from a clean
    /// slate rather than silently resurrecting an old session. Clearing an
    /// already-empty state is a no-op, and auto-login is unaffected (the
    /// clear rides ``AuthLaunchOptions/clearStaleAuthOnLaunch``, not the
    /// UI-test flag).
    ///
    /// Known, accepted first-launch blind spot: an install that predates this
    /// marker AND changes a `STACK_PROJECT_ID_*` LocalConfig override in the
    /// very build that introduces the marker infers `previous` from the NEW
    /// override table, so that one launch does not clear. The marker
    /// self-heals after a single launch (every later change is detected), and
    /// the alternative — inferring from the un-overridden defaults — would
    /// instead spuriously sign out every long-standing override install on
    /// upgrade, a worse trade.
    nonisolated static func detectAuthProjectSwitch(
        resolvedProjectID: String,
        buildDefaultProjectID: String,
        defaults: UserDefaults
    ) -> Bool {
        let previous = defaults.string(forKey: storedStackProjectIDKey) ?? buildDefaultProjectID
        defaults.set(resolvedProjectID, forKey: storedStackProjectIDKey)
        return previous != resolvedProjectID
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    private static var tokenStore: TokenStoreInit {
        #if DEBUG && targetEnvironment(simulator)
        .memory
        #else
        .keychain
        #endif
    }

    /// Parse optional string overrides from a bundled `LocalConfig.plist`.
    /// Stored as `[String: String]` so the result is Sendable.
    private static func localConfigStringOverrides(in bundle: Bundle) -> [String: String] {
        guard let path = bundle.path(forResource: "LocalConfig", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return [:]
        }
        var overrides: [String: String] = [:]
        for (key, value) in dict {
            if let stringValue = value as? String {
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    overrides[key] = trimmed
                }
            }
        }
        return overrides
    }
}
