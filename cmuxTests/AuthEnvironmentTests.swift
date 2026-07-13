import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Auth environment")
struct AuthEnvironmentTests {
    @Test("debug callback scheme uses sanitized tag")
    func debugCallbackSchemeUsesSanitizedTag() {
        #expect(
            AuthEnvironment.callbackScheme(
                environment: ["CMUX_TAG": "Safari Auth!"],
                bundleIdentifier: "com.cmuxterm.app.debug.safari-auth",
                isDebugBuild: true
            ) == "cmux-dev-safari-auth"
        )
    }

    @Test("release callback scheme ignores ambient tag")
    func releaseCallbackSchemeIgnoresAmbientTag() {
        #expect(
            AuthEnvironment.callbackScheme(
                environment: ["CMUX_TAG": "safari-auth"],
                bundleIdentifier: "com.cmuxterm.app",
                isDebugBuild: false
            ) == "cmux"
        )
        #expect(
            AuthEnvironment.callbackScheme(
                environment: ["CMUX_TAG": "safari-auth"],
                bundleIdentifier: "com.cmuxterm.app.nightly",
                isDebugBuild: false
            ) == "cmux-nightly"
        )
    }

    @Test("sign-in URL enters native wrapper")
    func signInURLEntersNativeWrapper() {
        // Regression coverage for #5720: the client must not derive auth URL
        // path segments from the user's system locale, such as /ru/.
        let url = AuthEnvironment.signInURL(
            callbackState: "state-1",
            environment: [
                "AppleLanguages": "(ru)",
                "LANG": "ru_RU.UTF-8",
                "LC_ALL": "ru_RU.UTF-8",
                "CMUX_AUTH_WWW_ORIGIN": "https://cmux.com",
                "CMUX_AUTH_CALLBACK_SCHEME": "cmux",
            ],
            bundleIdentifier: "com.cmuxterm.app"
        )

        assertNativeSignInURL(url)
    }

    @Test("tagged debug sign-in URL uses local origin and tag callback scheme")
    func taggedDebugSignInURLUsesLocalOriginAndTagCallbackScheme() throws {
        let url = AuthEnvironment.signInURL(
            callbackState: "state-1",
            environment: [
                "CMUX_TAG": "pair-auth",
                "CMUX_PORT": "4123",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.pair-auth"
        )

        #expect(url.scheme == "http")
        #expect(url.host == "localhost")
        #expect(url.port == 4123)
        #expect(url.path == "/handler/native-sign-in")

        let afterAuthReturnTo = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "after_auth_return_to" })?
            .value)
        let afterSignInURL = try #require(URL(string: afterAuthReturnTo))
        #expect(afterSignInURL.scheme == "http")
        #expect(afterSignInURL.host == "localhost")
        #expect(afterSignInURL.port == 4123)

        let nativeReturnTo = try #require(URLComponents(url: afterSignInURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "native_app_return_to" })?
            .value)
        let nativeCallbackURL = try #require(URL(string: nativeReturnTo))
        #expect(nativeCallbackURL.scheme == "cmux-dev-pair-auth")
        #expect(nativeCallbackURL.host == "auth-callback")
    }

    @Test("sign-in URL ignores locale-like environment values")
    func signInURLIgnoresLocaleLikeEnvironmentValues() {
        let englishURL = AuthEnvironment.signInURL(
            callbackState: "state-1",
            environment: [
                "AppleLanguages": "(en)",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "CMUX_AUTH_WWW_ORIGIN": "https://cmux.com",
                "CMUX_AUTH_CALLBACK_SCHEME": "cmux",
            ],
            bundleIdentifier: "com.cmuxterm.app"
        )
        let russianURL = AuthEnvironment.signInURL(
            callbackState: "state-1",
            environment: [
                "AppleLanguages": "(ru)",
                "LANG": "ru_RU.UTF-8",
                "LC_ALL": "ru_RU.UTF-8",
                "CMUX_AUTH_WWW_ORIGIN": "https://cmux.com",
                "CMUX_AUTH_CALLBACK_SCHEME": "cmux",
            ],
            bundleIdentifier: "com.cmuxterm.app"
        )

        #expect(russianURL == englishURL)
    }

    @Test("billing checkout follows app web origin unless billing origin is explicit")
    func billingCheckoutFollowsAppWebOriginUnlessBillingOriginIsExplicit() {
        let appOriginURL = AuthEnvironment.resolvedBillingCheckoutURL(
            environment: [
                "CMUX_AUTH_CALLBACK_SCHEME": "cmux-dev",
                "CMUX_WWW_ORIGIN": "http://127.0.0.1:4278",
            ]
        )
        #expect(appOriginURL.scheme == "http")
        #expect(appOriginURL.host == "localhost")
        #expect(appOriginURL.port == 4278)
        #expect(appOriginURL.path == "/api/billing/checkout")
        #expect(URLComponents(url: appOriginURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name == "cmux_external_browser" && $0.value == "1" }) == true)
        #expect(URLComponents(url: appOriginURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name == "cmux_scheme" && $0.value == "cmux-dev" }) == true)

        let overrideURL = AuthEnvironment.resolvedBillingCheckoutURL(
            environment: [
                "CMUX_WWW_ORIGIN": "http://localhost:4278",
                "CMUX_BILLING_WWW_ORIGIN": "https://billing-preview.example",
                "CMUX_AUTH_CALLBACK_SCHEME": "cmux-dev-preview",
            ]
        )
        #expect(overrideURL.scheme == "https")
        #expect(overrideURL.host == "billing-preview.example")
        #expect(overrideURL.path == "/api/billing/checkout")
        #expect(URLComponents(url: overrideURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name == "cmux_scheme" && $0.value == "cmux-dev-preview" }) == true)
    }

    @Test("billing portal follows app web origin unless billing origin is explicit")
    func billingPortalFollowsAppWebOriginUnlessBillingOriginIsExplicit() {
        let appOriginURL = AuthEnvironment.resolvedBillingPortalURL(
            environment: [
                "CMUX_WWW_ORIGIN": "http://127.0.0.1:4278",
            ]
        )
        #expect(appOriginURL.scheme == "http")
        #expect(appOriginURL.host == "localhost")
        #expect(appOriginURL.port == 4278)
        #expect(appOriginURL.path == "/api/billing/portal")

        let overrideURL = AuthEnvironment.resolvedBillingPortalURL(
            environment: [
                "CMUX_WWW_ORIGIN": "http://localhost:4278",
                "CMUX_BILLING_WWW_ORIGIN": "https://billing-preview.example",
            ]
        )
        #expect(overrideURL.scheme == "https")
        #expect(overrideURL.host == "billing-preview.example")
        #expect(overrideURL.path == "/api/billing/portal")
    }

    @Test("billing checkout default origin follows build web origin")
    func billingCheckoutDefaultOriginFollowsBuildWebOrigin() {
        let url = AuthEnvironment.resolvedBillingCheckoutURL(
            environment: [
                "CMUX_PORT": "4278",
            ]
        )

        #if DEBUG
        #expect(url.scheme == "http")
        #expect(url.host == "localhost")
        #expect(url.port == 4278)
        #else
        #expect(url.scheme == "https")
        #expect(url.host == "cmux.com")
        #expect(url.port == nil)

        let releaseDefaultURL = AuthEnvironment.resolvedBillingCheckoutURL(environment: [:])
        #expect(releaseDefaultURL.scheme == "https")
        #expect(releaseDefaultURL.host == "cmux.com")
        #expect(releaseDefaultURL.port == nil)
        #endif

        #expect(url.path == "/api/billing/checkout")
        #if DEBUG
        let expectedScheme = "cmux-dev"
        #else
        let expectedScheme = "cmux"
        #endif
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name == "cmux_scheme" && $0.value == expectedScheme }) == true)
    }

    @Test("tagged debug app pricing uses launch web origin before dotfile fallback")
    func taggedDebugAppPricingUsesLaunchWebOriginBeforeDotfileFallback() {
        let environment = [
            "CMUX_AUTH_WWW_ORIGIN": "http://127.0.0.1:9210",
            "CMUX_PORT": "9210",
        ]

        let pricingURL = AuthEnvironment.resolvedPricingURL(environment: environment)
        #expect(pricingURL.scheme == "http")
        #expect(pricingURL.host == "localhost")
        #expect(pricingURL.port == 9210)
        #expect(pricingURL.path == "/pricing")

        let appPricingURL = AuthEnvironment.resolvedAppPricingURL(environment: environment)
        #expect(appPricingURL.scheme == "http")
        #expect(appPricingURL.host == "localhost")
        #expect(appPricingURL.port == 9210)
        #expect(appPricingURL.path == "/app-pricing")

        let appProWelcomeURL = AuthEnvironment.resolvedAppProWelcomeURL(environment: environment)
        #expect(appProWelcomeURL.scheme == "http")
        #expect(appProWelcomeURL.host == "localhost")
        #expect(appProWelcomeURL.port == 9210)
        #expect(appProWelcomeURL.path == "/app-pro-welcome")
    }

    @Test("Pro upgrade workspace reuse keeps a live tracked workspace")
    func proUpgradeWorkspaceReuseKeepsLiveTrackedWorkspace() {
        var state = ProUpgradeWorkspaceReuseState()
        let workspaceId = UUID()

        state.recordCreatedWorkspace(id: workspaceId)

        #expect(state.reusableWorkspaceID { $0 == workspaceId } == workspaceId)
        #expect(state.workspaceId == workspaceId)
    }

    @Test("Pro upgrade workspace reuse clears stale tracked workspace")
    func proUpgradeWorkspaceReuseClearsStaleTrackedWorkspace() {
        var state = ProUpgradeWorkspaceReuseState()
        let closedWorkspaceId = UUID()

        state.recordCreatedWorkspace(id: closedWorkspaceId)

        #expect(state.reusableWorkspaceID { _ in false } == nil)
        #expect(state.workspaceId == nil)
    }

    @Test("Pro welcome checklist automatic presentation requires Pro plan, feature flag, and unseen defaults")
    func proWelcomeChecklistAutomaticPresentationRequiresAllGates() {
        #expect(ProWelcomeChecklistPresenter.shouldPresentAutomatically(isPro: true, seen: false, flagEnabled: true))
        #expect(!ProWelcomeChecklistPresenter.shouldPresentAutomatically(isPro: false, seen: false, flagEnabled: true))
        #expect(!ProWelcomeChecklistPresenter.shouldPresentAutomatically(isPro: true, seen: true, flagEnabled: true))
        #expect(!ProWelcomeChecklistPresenter.shouldPresentAutomatically(isPro: true, seen: false, flagEnabled: false))
    }

    @Test("Pro welcome checklist consume gate persists once only")
    func proWelcomeChecklistConsumeGatePersistsOnceOnly() throws {
        let suiteName = "cmuxTests.proWelcomeChecklist.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(defaults.bool(forKey: ProWelcomeChecklistPresenter.seenDefaultsKey) == false)
        #expect(ProWelcomeChecklistPresenter.consumeAutomaticPresentation(
            isPro: true,
            flagEnabled: true,
            defaults: defaults
        ))
        #expect(defaults.bool(forKey: ProWelcomeChecklistPresenter.seenDefaultsKey))
        #expect(!ProWelcomeChecklistPresenter.consumeAutomaticPresentation(
            isPro: true,
            flagEnabled: true,
            defaults: defaults
        ))
    }

    @Test("Pro welcome checklist consume gate does not persist when blocked")
    func proWelcomeChecklistConsumeGateDoesNotPersistWhenBlocked() throws {
        let suiteName = "cmuxTests.proWelcomeChecklist.blocked.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(!ProWelcomeChecklistPresenter.consumeAutomaticPresentation(
            isPro: false,
            flagEnabled: true,
            defaults: defaults
        ))
        #expect(!defaults.bool(forKey: ProWelcomeChecklistPresenter.seenDefaultsKey))

        #expect(!ProWelcomeChecklistPresenter.consumeAutomaticPresentation(
            isPro: true,
            flagEnabled: false,
            defaults: defaults
        ))
        #expect(!defaults.bool(forKey: ProWelcomeChecklistPresenter.seenDefaultsKey))
    }

    @MainActor
    @Test("Pro upgrade workspace focus fails for a windowless tracked context")
    func proUpgradeWorkspaceFocusFailsForWindowlessTrackedContext() {
        let defaults = UserDefaults.standard
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        BrowserAvailabilitySettings.setDisabled(false)
        defer {
            if let previousBrowserDisabled {
                defaults.set(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey)
            } else {
                defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
                NotificationCenter.default.post(name: BrowserAvailabilitySettings.didChangeNotification, object: nil)
            }
        }

        let appDelegate = AppDelegate()
        let manager = TabManager()
        let pricingURL = URL(string: "https://cmux.com/app-pricing?cmux_app=1")!
        let workspace = manager.addWorkspace(
            title: "cmux Pro",
            initialSurface: .browser,
            initialBrowserURL: pricingURL,
            initialBrowserOmnibarVisible: false,
            initialBrowserTransparentBackground: true
        )
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        #expect(appDelegate.focusProUpgradeWorkspace(workspaceId: workspace.id, url: pricingURL) == false)
    }
}

private func assertNativeSignInURL(_ url: URL) {
    #expect(url.scheme == "https")
    #expect(url.host == "cmux.com")
    #expect(url.path == "/handler/native-sign-in")
    #expect(!urlHasLeadingLocaleSegment(url))

    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let afterAuthReturnTo = components.queryItems?.first(where: { $0.name == "after_auth_return_to" })?.value,
          let afterSignInURL = URL(string: afterAuthReturnTo)
    else {
        Issue.record("sign-in URL must include an after_auth_return_to URL")
        return
    }

    #expect(afterSignInURL.scheme == "https")
    #expect(afterSignInURL.host == "cmux.com")
    #expect(afterSignInURL.path == "/handler/after-sign-in")
    #expect(!urlHasLeadingLocaleSegment(afterSignInURL))

    guard let afterSignInComponents = URLComponents(url: afterSignInURL, resolvingAgainstBaseURL: false),
          let nativeReturnTo = afterSignInComponents.queryItems?.first(where: { $0.name == "native_app_return_to" })?.value,
          let nativeCallbackURL = URL(string: nativeReturnTo)
    else {
        Issue.record("after-sign-in URL must include a native_app_return_to URL")
        return
    }

    #expect(nativeCallbackURL.scheme == "cmux")
    #expect(nativeCallbackURL.host == "auth-callback")

    let nativeCallbackComponents = URLComponents(url: nativeCallbackURL, resolvingAgainstBaseURL: false)
    #expect(nativeCallbackComponents?.queryItems?.first { $0.name == "cmux_auth_state" }?.value == "state-1")
}

private func urlHasLeadingLocaleSegment(_ url: URL) -> Bool {
    guard let firstSegment = url.pathComponents.dropFirst().first else {
        return false
    }
    return isLocalePathSegment(firstSegment)
}

private func isLocalePathSegment(_ segment: String) -> Bool {
    let parts = segment.split(separator: "-")
    guard let language = parts.first,
          (2...3).contains(language.count),
          language.allSatisfy(\.isLetter)
    else {
        return false
    }
    return parts.dropFirst().allSatisfy { subtag in
        (2...4).contains(subtag.count) && subtag.allSatisfy(\.isLetter)
    }
}
