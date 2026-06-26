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
    /// Recognizes/parses native auth callback URLs delivered back from Safari.
    public let callbackRouter: AuthCallbackRouter
    /// Handles native browser callback token seeding and coordinator publishing.
    public let browserSignIn: HostBrowserSignInFlow

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

        let overrides = Self.localConfigStringOverrides(in: bundle)
        let buildEnvironment: CMUXAuthEnvironment = Self.isDevelopmentBuild ? .development : .production
        let authEnvironment = Self.authEnvironment(
            buildEnvironment: buildEnvironment,
            bundle: bundle,
            overrides: overrides
        )
        let resolvedConfig = AuthConfig(
            environment: authEnvironment,
            overrides: overrides
        )
        self.config = resolvedConfig

        let tokenStore = StackProjectKeychainTokenStore(projectId: resolvedConfig.stack.projectId)
        let client = StackAuthClient(
            config: resolvedConfig,
            tokenStore: .custom(tokenStore)
        )
        let sessionCache = CMUXAuthSessionCache(
            keyValueStore: defaults,
            key: "auth_has_tokens"
        )
        let userCache = CMUXAuthIdentityStore(
            keyValueStore: defaults,
            key: "auth_cached_user"
        )
        let teamSelection = CMUXAuthTeamSelectionStore(
            keyValueStore: defaults,
            key: "auth_selected_team"
        )
        let launch = AuthLaunchOptions(
            clearAuthRequested: environment["CMUX_UITEST_CLEAR_AUTH"] == "1",
            mockDataEnabled: UITestConfig.mockDataEnabled,
            environment: environment,
            includesDevAuth: policy.includesFortyTwoShortcut
        )
        let authCallbackScheme = Self.authCallbackScheme(
            bundle: bundle,
            authEnvironment: authEnvironment,
            overrides: overrides
        )
        let canUseNativeMagicLinkCallback = !(authEnvironment == .production && authCallbackScheme == "cmux-ios-dev")
        // Break the coordinator <-> push cycle: the coordinator is built first
        // and reaches the push service (for its post-sign-in token re-upload)
        // through a deferred async hook that is pointed at the push service once
        // it exists. The push service reads tokens directly from the coordinator.
        let deferredSignIn = DeferredSignInHook()
        let magicLinkCallbackURLProvider = DeferredMagicLinkCallbackURLProvider()
        let monitor = reachability
        let anchor = AuthPresentationContextProvider()
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: sessionCache,
            userCache: userCache,
            teamSelection: teamSelection,
            anchor: anchor,
            config: resolvedConfig,
            magicLinkCallbackURLProvider: { magicLinkCallbackURLProvider.urlString() },
            launch: launch,
            isOnline: { await monitor.isOnline },
            onSignedIn: { await deferredSignIn.run() }
        )
        let callbackRouter = AuthCallbackRouter(extraAllowedScheme: authCallbackScheme)
        self.callbackRouter = callbackRouter
        let browserSignIn = HostBrowserSignInFlow(
            coordinator: coordinator,
            tokenStore: tokenStore,
            sessionFactory: ASWebBrowserAuthSessionFactory(anchor: anchor),
            callbackRouter: callbackRouter,
            makeSignInURL: { callbackState in
                Self.nativeSignInURL(
                    websiteOrigin: resolvedConfig.apiBaseURL,
                    callbackScheme: authCallbackScheme,
                    callbackState: callbackState
                )
            },
            callbackScheme: { authCallbackScheme },
            allowsStatelessExternalCallbacks: false
        )
        self.browserSignIn = browserSignIn
        magicLinkCallbackURLProvider.set {
            guard canUseNativeMagicLinkCallback else { return nil }
            Self.nativeMagicLinkCallbackURL(
                websiteOrigin: resolvedConfig.apiBaseURL,
                callbackScheme: authCallbackScheme,
                callbackState: Self.makeCallbackState()
            )
        }
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

    private static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    static func authEnvironment(
        buildEnvironment: CMUXAuthEnvironment,
        bundle: Bundle = .main,
        overrides: [String: String]
    ) -> CMUXAuthEnvironment {
        if let override = overrides["AuthEnvironment"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return CMUXAuthEnvironment(rawValue: override.lowercased()) ?? buildEnvironment
        }
        if let override = bundle.object(forInfoDictionaryKey: "CMUXAuthEnvironment") as? String {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return CMUXAuthEnvironment(rawValue: trimmed.lowercased()) ?? buildEnvironment
            }
        }
        return buildEnvironment
    }

    static func authCallbackScheme(
        bundle: Bundle,
        authEnvironment: CMUXAuthEnvironment,
        overrides: [String: String]
    ) -> String {
        let resolvedScheme: String
        if let override = overrides["AuthCallbackScheme"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            resolvedScheme = override
        } else if let scheme = bundle.object(forInfoDictionaryKey: "CMUXIOSAuthCallbackScheme") as? String {
            let trimmed = scheme.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                resolvedScheme = trimmed
            } else {
                resolvedScheme = isDevelopmentBuild ? "cmux-ios-dev" : "cmux-ios"
            }
        } else {
            resolvedScheme = isDevelopmentBuild ? "cmux-ios-dev" : "cmux-ios"
        }
        return resolvedScheme
    }

    static func nativeSignInURL(
        websiteOrigin: String,
        callbackScheme: String,
        callbackState: String
    ) -> URL {
        let afterSignIn = nativeAfterSignInURL(
            websiteOrigin: websiteOrigin,
            callbackScheme: callbackScheme,
            callbackState: callbackState
        )

        let origin = URL(string: websiteOrigin) ?? URL(string: "https://cmux.com")!
        let nativeSignIn = origin.appendingPathComponent("handler/native-sign-in", isDirectory: false)
        var nativeComponents = URLComponents(url: nativeSignIn, resolvingAgainstBaseURL: false)!
        nativeComponents.queryItems = [
            URLQueryItem(name: "after_auth_return_to", value: afterSignIn.absoluteString),
        ]
        return nativeComponents.url!
    }

    static func nativeMagicLinkCallbackURL(
        websiteOrigin: String,
        callbackScheme: String,
        callbackState: String
    ) -> URL {
        let afterSignIn = nativeAfterSignInURL(
            websiteOrigin: websiteOrigin,
            callbackScheme: callbackScheme,
            callbackState: callbackState
        )

        let origin = URL(string: websiteOrigin) ?? URL(string: "https://cmux.com")!
        let magicLink = origin.appendingPathComponent("handler/mobile-magic-link-callback", isDirectory: false)
        var magicComponents = URLComponents(url: magicLink, resolvingAgainstBaseURL: false)!
        magicComponents.queryItems = [
            URLQueryItem(name: "native_app_return_to", value: "\(callbackScheme)://auth-callback?cmux_auth_state=\(callbackState)"),
        ]
        return magicComponents.url!
    }

    private static func nativeAfterSignInURL(
        websiteOrigin: String,
        callbackScheme: String,
        callbackState: String
    ) -> URL {
        let origin = URL(string: websiteOrigin) ?? URL(string: "https://cmux.com")!
        let afterSignIn = origin.appendingPathComponent("handler/after-sign-in", isDirectory: false)
        var afterComponents = URLComponents(url: afterSignIn, resolvingAgainstBaseURL: false)!
        afterComponents.queryItems = [
            URLQueryItem(
                name: "native_app_return_to",
                value: "\(callbackScheme)://auth-callback?cmux_auth_state=\(callbackState)"
            ),
            URLQueryItem(name: "cmux_native_platform", value: "mobile"),
        ]
        return afterComponents.url!
    }

    private static func makeCallbackState() -> String {
        UUID().uuidString.lowercased()
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
