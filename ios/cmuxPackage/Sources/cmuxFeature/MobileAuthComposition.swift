import CMUXAuthCore
import CMUXMobileCore
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
    /// The push registration service, activated after notification permission.
    public let pushRegistration: PushRegistrationService
    /// The resolved configuration (used for diagnostics + push API base URL).
    public let config: AuthConfig
    /// Which Stack project this build signs in to. DEBUG defaults to
    /// development and Release to production, but an ``authEnvironmentOverrideKey``
    /// entry (from `LocalConfig.plist`, or the Info.plist value
    /// `ios/scripts/reload.sh --prod-auth` bakes) flips it, so a sideloaded
    /// dev build can test production account behavior. Build compatibility is
    /// enforced separately and remains exact-tag DEV to DEV. Exposed so the
    /// identity provider can label the channel its user ids belong to.
    public let authEnvironment: CMUXAuthEnvironment
    /// Exact installed-app boundary used by every persistent subsystem.
    public let appNamespace: MobileIOSAppNamespace?
    /// Exact Keychain group claimed by this signed bundle.
    public let keychainAccessGroup: String?
    /// The runtime Production/Staging switch surface for Settings: the ACTIVE
    /// environment THIS composition resolved when it was built, and whether a
    /// build-time override (`LocalConfig.plist` or an Info.plist bake) pins
    /// this build's backend. The live switch transaction rebuilds the whole
    /// composition after storing the override, so `active` converges to the
    /// user's choice by re-injection from the new graph (no relaunch notice).
    public let backendEnvironmentSwitch: CMUXBackendEnvironmentSwitchState

    /// iOS OAuth must not inherit Safari cookies from another cmux build.
    nonisolated static let oauthBrowserSessionPrivacy: OAuthBrowserSessionPrivacy = .ephemeral

    /// UIKit protected-data availability bridge used by auth session restore.
    /// Internal (not private) so the shutdown test can prove the observation
    /// is disconnected through the injected notification center.
    let protectedDataAvailability: ProtectedDataAvailability

    /// A reachability monitor used to fail sign-in flows fast when offline.
    private let reachability: any ReachabilityProviding

    /// Owns bootstrap and protected-data revalidation tasks for this graph.
    private let taskOwner: MobileAuthTaskOwner

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
    ///   - diagnosticLog: Optional privacy-safe app diagnostic recorder.
    ///   - notificationCenter: The center delivering protected-data
    ///     availability notifications. Injected so the shutdown test can post
    ///     through a private center; production uses `.default`.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        reachability: any ReachabilityProviding,
        policy: MobileAuthBuildPolicy = .current,
        diagnosticLog: DiagnosticLog? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.reachability = reachability
        let appNamespace = MobileIOSAppNamespace(
            bundleIdentifier: bundle.bundleIdentifier
        )
        let keychainAccessGroup = Self.keychainAccessGroup(in: bundle)
        self.appNamespace = appNamespace
        self.keychainAccessGroup = keychainAccessGroup

        let buildOverrides = Self.authOverrides(
            localConfig: Self.localConfigStringOverrides(in: bundle),
            bakedAuthEnvironment: bundle.object(
                forInfoDictionaryKey: Self.authEnvironmentInfoPlistKey
            ) as? String,
            bakedAPIBaseURL: bundle.object(
                forInfoDictionaryKey: Self.apiBaseURLInfoPlistKey
            ) as? String
        )
        // The Settings picker's persisted choice, read from the same injected
        // defaults the caches use. It merges BELOW every build-time override,
        // so tagged dev builds keep their baked isolation and the runtime
        // switch takes effect exactly where nothing is baked (TestFlight/App
        // Store builds).
        let runtimeBackendOverride = CMUXBackendEnvironmentOverride.load(from: defaults)
        let overrides = Self.mergingRuntimeBackendOverride(
            runtimeBackendOverride,
            into: buildOverrides
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
        self.backendEnvironmentSwitch = CMUXBackendEnvironmentSwitchState(
            active: Self.activeBackendEnvironment(
                resolvedAPIBaseURL: resolvedConfig.apiBaseURL
            ),
            isPinnedByBuild: Self.backendEnvironmentIsPinned(
                buildOverrides: buildOverrides
            )
        )

        let client = StackAuthClient(
            config: resolvedConfig,
            tokenStore: Self.tokenStore(
                appNamespace: appNamespace,
                accessGroup: keychainAccessGroup,
                legacyProjectID: resolvedConfig.stack.projectId
            ),
            oauthBrowserSessionPrivacy: Self.oauthBrowserSessionPrivacy
        )
        let availability = ProtectedDataAvailability(
            notificationCenter: notificationCenter
        )
        let sessionCache = CMUXAuthSessionCache(
            keyValueStore: defaults,
            key: Self.sessionCacheDefaultsKey
        )
        let hadCachedSessionAtLaunch = sessionCache.hasTokens
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
        let includesDevAuth = Self.includesDevAuth(
            policy: policy,
            resolvedEnvironment: resolvedEnvironment
        )
        let launch = AuthLaunchOptions(
            clearAuthRequested: environment["CMUX_UITEST_CLEAR_AUTH"] == "1",
            mockDataEnabled: UITestConfig.mockDataEnabled,
            environment: environment,
            includesDevAuth: includesDevAuth,
            clearStaleAuthOnLaunch: authProjectSwitched,
            replaceStoredSessionWithAutoLogin: Self.shouldReplaceStoredSessionWithAutoLogin(
                includesDevAuth: includesDevAuth,
                environment: environment
            )
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
            isTokenStorageAvailable: { await MainActor.run { availability.isAvailable } },
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
        self.protectedDataAvailability = availability
        self.taskOwner = MobileAuthTaskOwner(
            diagnosticLog: diagnosticLog,
            shouldObserveCachedRestore: hadCachedSessionAtLaunch
                && !launch.clearAuthRequested
                && !launch.mockDataEnabled
                && !launch.shouldClearStoredSessionBeforePriming
        )
    }

    /// Begin asynchronous session restore (call once after construction).
    public func start() {
        taskOwner.recordRestoreStarted()
        protectedDataAvailability.startObserving { [coordinator, taskOwner] in
            taskOwner.revalidateSession(using: coordinator)
        }
        coordinator.start()
        taskOwner.observeRestore(using: coordinator)
    }

    /// Tears down this graph's cross-lifetime observation when the app swaps
    /// composition roots (the live backend switch). After shutdown, a
    /// protected-data availability notification must not trigger a session
    /// revalidation, and the bootstrap/revalidation tasks are cancelled so no
    /// auth work from the old environment races the new graph. Cancellation is
    /// not joined: both tasks only touch this graph's own coordinator, which is
    /// discarded with it. The struct may briefly outlive the swap; the task
    /// owner's `deinit` remains the backstop.
    public func shutdown() {
        protectedDataAvailability.stopObserving()
        taskOwner.cancelAll()
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

    /// The Info.plist key carrying the tagged build's isolated web origin.
    /// `ios/scripts/reload.sh` bakes the same port used by the matching macOS
    /// tag so auth, trust-broker, and device routes cannot drift to another
    /// agent's localhost server.
    nonisolated static let apiBaseURLInfoPlistKey = "CMUXApiBaseURL"

    /// The override-table key carrying the cmux web API base URL.
    nonisolated static let apiBaseURLOverrideKey = "ApiBaseURL"

    /// The override-table key moving the whole web origin: it retargets the
    /// magic-link callback and is the default API base when no explicit
    /// ``apiBaseURLOverrideKey`` entry exists (see `CmuxAuthRuntime.AuthConfig`).
    nonisolated static let webOriginURLOverrideKey = "WebOriginURL"

    /// Merge the Info.plist-baked auth environment into the `LocalConfig.plist`
    /// override table. An explicit LocalConfig entry wins over the bake
    /// (mirroring presence resolution, where the local override table beats the
    /// baked Info.plist value); blank baked values are ignored so the empty
    /// `$(CMUX_IOS_AUTH_ENV)` expansion in a normal build contributes nothing.
    nonisolated static func authOverrides(
        localConfig: [String: String],
        bakedAuthEnvironment: String?,
        bakedAPIBaseURL: String? = nil
    ) -> [String: String] {
        var overrides = localConfig
        if overrides[authEnvironmentOverrideKey] == nil,
           let baked = bakedAuthEnvironment?.trimmingCharacters(in: .whitespacesAndNewlines),
           !baked.isEmpty {
            overrides[authEnvironmentOverrideKey] = baked
        }
        if overrides[apiBaseURLOverrideKey] == nil,
           let baked = bakedAPIBaseURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !baked.isEmpty {
            overrides[apiBaseURLOverrideKey] = baked
        }
        return overrides
    }

    /// Merge the Settings picker's persisted backend override BELOW every
    /// build-time override: each key is contributed only when nothing already
    /// decides it, so the per-key precedence is `LocalConfig.plist` > baked
    /// Info.plist > runtime override > build default. Baked values are the
    /// tagged-dev-build isolation mechanism and keep winning; TestFlight and
    /// App Store builds bake nothing, so the runtime override applies exactly
    /// there. A production override contributes nothing ("no key" and
    /// production are indistinguishable by design), leaving today's
    /// resolution byte-identical.
    nonisolated static func mergingRuntimeBackendOverride(
        _ backendOverride: CMUXBackendEnvironmentOverride,
        into overrides: [String: String]
    ) -> [String: String] {
        guard backendOverride == .staging else { return overrides }
        var merged = overrides
        let contribution: [String: String] = [
            // The staging web deployment authenticates against the
            // development Stack project.
            authEnvironmentOverrideKey: "development",
            apiBaseURLOverrideKey: CMUXBackendEnvironmentOverride.stagingWebOrigin,
            // Moves the magic-link callback with the API base, so staging
            // magic-link emails cannot point at the per-environment default.
            webOriginURLOverrideKey: CMUXBackendEnvironmentOverride.stagingWebOrigin,
        ]
        for (key, value) in contribution where merged[key] == nil {
            merged[key] = value
        }
        return merged
    }

    /// Whether a build-time source (`LocalConfig.plist` or an Info.plist
    /// bake) already decides a backend key, so the runtime override cannot
    /// steer this build. Settings uses this to explain that a tagged dev
    /// build's backend is pinned at build time instead of offering a picker
    /// that would not take effect.
    nonisolated static func backendEnvironmentIsPinned(
        buildOverrides: [String: String]
    ) -> Bool {
        [
            authEnvironmentOverrideKey,
            apiBaseURLOverrideKey,
            webOriginURLOverrideKey,
        ].contains { buildOverrides[$0] != nil }
    }

    /// Map the resolved web API origin back to the picker's two channels: the
    /// staging origin means the staging backend is ACTIVE for this
    /// composition; anything else (cmux.com, a tagged build's isolated
    /// localhost origin, the localhost dev default) reports as production, so
    /// the staging badge and the Settings picker key off the origin the
    /// process actually talks to.
    nonisolated static func activeBackendEnvironment(
        resolvedAPIBaseURL: String
    ) -> CMUXBackendEnvironmentOverride {
        resolvedAPIBaseURL == CMUXBackendEnvironmentOverride.stagingWebOrigin
            ? .staging
            : .production
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

    /// Whether launch enables the `42` debug sign-in shortcut. It signs in
    /// with fixed development-project credentials, so it exists only where
    /// those credentials belong: builds whose RESOLVED auth environment is
    /// development. A `--prod-auth` build still compiles the shortcut (DEBUG
    /// policy) but must not expose a known-credential sign-in path against
    /// the production Stack project.
    nonisolated static func includesDevAuth(
        policy: MobileAuthBuildPolicy,
        resolvedEnvironment: CMUXAuthEnvironment
    ) -> Bool {
        policy.includesFortyTwoShortcut && resolvedEnvironment == .development
    }

    /// Whether an explicit resolved development-auth profile may replace a
    /// persisted session. A DEBUG build can be pointed at production with
    /// `--prod-auth`; that channel must never let the replacement marker clear
    /// a valid production session.
    nonisolated static func shouldReplaceStoredSessionWithAutoLogin(
        includesDevAuth: Bool,
        environment: [String: String]
    ) -> Bool {
        includesDevAuth
            && environment["CMUX_DEV_AUTH_REPLACE_SESSION"] == "1"
            && !(environment["CMUX_UITEST_STACK_EMAIL"] ?? "").isEmpty
            && !(environment["CMUX_UITEST_STACK_PASSWORD"] ?? "").isEmpty
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

    private static func tokenStore(
        appNamespace: MobileIOSAppNamespace?,
        accessGroup: String?,
        legacyProjectID: String
    ) -> TokenStoreInit {
        #if DEBUG && targetEnvironment(simulator)
        .memory
        #else
        guard let appNamespace else {
            return .none
        }
        return .custom(
            KeychainStackTokenStore(
                service: appNamespace.keychainService(
                    base: "com.cmuxterm.app.auth"
                ),
                accessGroup: accessGroup,
                legacyProjectID: legacyProjectID
            )
        )
        #endif
    }

    private static func keychainAccessGroup(in bundle: Bundle) -> String? {
        let value = bundle.object(
            forInfoDictionaryKey: "CMUXKeychainAccessGroup"
        ) as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        return trimmed
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

/// Lifetime owner for auth operations started from synchronous UIKit seams.
@MainActor
private final class MobileAuthTaskOwner {
    private let diagnosticLog: DiagnosticLog?
    private let shouldObserveCachedRestore: Bool
    private var restoreTask: Task<Void, Never>?
    private var revalidationTask: Task<Void, Never>?

    init(
        diagnosticLog: DiagnosticLog?,
        shouldObserveCachedRestore: Bool
    ) {
        self.diagnosticLog = diagnosticLog
        self.shouldObserveCachedRestore = shouldObserveCachedRestore
    }

    func recordRestoreStarted() {
        guard shouldObserveCachedRestore else { return }
        diagnosticLog?.recordAppEvent(.authRestoreStarted)
    }

    func observeRestore(using coordinator: AuthCoordinator) {
        guard shouldObserveCachedRestore, let diagnosticLog else { return }
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self, coordinator] in
            await coordinator.awaitBootstrapped()
            guard !Task.isCancelled else { return }
            diagnosticLog.recordAppEvent(
                coordinator.isAuthenticated ? .authRestoreSucceeded : .authRestoreFailed,
                failure: coordinator.isAuthenticated ? nil : .authorizationFailed,
                count: coordinator.isAuthenticated ? 1 : nil
            )
            self?.restoreTask = nil
        }
    }

    func revalidateSession(using coordinator: AuthCoordinator) {
        revalidationTask?.cancel()
        revalidationTask = Task { @MainActor [weak self, coordinator] in
            await coordinator.revalidateSession()
            guard !Task.isCancelled else { return }
            self?.revalidationTask = nil
        }
    }

    /// Cancels every owned task when the composition shuts down (the live
    /// backend switch). Same teardown as `deinit`, which stays as the backstop
    /// for owners that never call shutdown.
    func cancelAll() {
        restoreTask?.cancel()
        restoreTask = nil
        revalidationTask?.cancel()
        revalidationTask = nil
    }

    deinit {
        restoreTask?.cancel()
        revalidationTask?.cancel()
    }
}
