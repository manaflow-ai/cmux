import AppKit
import CMUXAuthCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Auth environment")
struct AuthEnvironmentTests {
    @Test("macOS production auth override selects the production Stack project")
    func macOSProductionAuthOverrideSelectsProductionStackProject() {
        #expect(AuthEnvironment.resolvedStackAuthEnvironment(
            environment: ["CMUX_AUTH_ENVIRONMENT": " production "],
            isDebugBuild: true
        ) == .production)
        #expect(AuthEnvironment.resolvedStackProjectID(
            environment: ["CMUX_AUTH_ENVIRONMENT": "production"],
            isDebugBuild: true
        ) == "9790718f-14cd-4f7e-824d-eaf527a82b82")
        #expect(AuthEnvironment.resolvedStackPublishableClientKey(
            environment: ["CMUX_AUTH_ENVIRONMENT": "production"],
            isDebugBuild: true
        ) == "pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr")
    }

    @Test("invalid macOS auth override fails toward the build channel")
    func invalidMacOSAuthOverrideFailsTowardBuildChannel() {
        #expect(AuthEnvironment.resolvedStackAuthEnvironment(
            environment: ["CMUX_AUTH_ENVIRONMENT": "staging"],
            isDebugBuild: true
        ) == .development)
        #expect(AuthEnvironment.resolvedStackAuthEnvironment(
            environment: ["CMUX_AUTH_ENVIRONMENT": "staging"],
            isDebugBuild: false
        ) == .production)
    }

    @Test("explicit Stack values override the selected auth channel")
    func explicitStackValuesOverrideSelectedAuthChannel() {
        let environment = [
            "CMUX_AUTH_ENVIRONMENT": "production",
            "CMUX_STACK_PROJECT_ID": "test-project",
            "CMUX_STACK_PUBLISHABLE_CLIENT_KEY": "test-key",
        ]
        #expect(AuthEnvironment.resolvedStackProjectID(
            environment: environment,
            isDebugBuild: true
        ) == "test-project")
        #expect(AuthEnvironment.resolvedStackPublishableClientKey(
            environment: environment,
            isDebugBuild: true
        ) == "test-key")
    }

    @Test("Iroh broker uses shared staging in debug without moving other APIs")
    func irohBrokerUsesSharedStagingInDebugWithoutMovingOtherAPIs() {
        let defaultURL = AuthEnvironment.resolvedIrohBrokerBaseURL(
            environment: ["CMUX_VM_API_BASE_URL": "http://localhost:9450"],
            isDebugBuild: true
        )
        #expect(defaultURL?.absoluteString == "https://cmux-staging.vercel.app")

        let overrideURL = AuthEnvironment.resolvedIrohBrokerBaseURL(
            environment: [
                "CMUX_IROH_BROKER_BASE_URL": "https://broker.example.test/root/",
                "CMUX_VM_API_BASE_URL": "http://localhost:9450",
            ],
            isDebugBuild: true
        )
        #expect(overrideURL?.absoluteString == "https://broker.example.test/root/")

        let releaseURL = AuthEnvironment.resolvedIrohBrokerBaseURL(
            environment: [:],
            isDebugBuild: false
        )
        #expect(releaseURL?.absoluteString == "https://cmux.com")

        #expect(AuthEnvironment.resolvedIrohBrokerBaseURL(
            environment: ["CMUX_IROH_BROKER_BASE_URL": ":// malformed"],
            isDebugBuild: true
        ) == nil)
    }

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

    @MainActor
    @Test("app web URLs carry the Ghostty colors and cmux product accent")
    func appWebURLsCarryGhosttyColorsAndCmuxProductAccent() throws {
        let base = try #require(URL(string: "https://cmux.com/app-pricing?interval=year&accent=%23000000"))
        let theme = AppWebThemeSnapshot(
            appearance: "dark",
            background: "#112233",
            foreground: "#DDEEFF",
            accent: "#0091FF"
        )

        let url = ProUpgradePresenter.decoratedAppWebURL(base, theme: theme)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(values["interval"] == "year")
        #expect(values["appearance"] == "dark")
        #expect(values["background"] == "#112233")
        #expect(values["foreground"] == "#DDEEFF")
        #expect(values["accent"] == "#0091FF")
        #expect(values["accent_on_background"] == theme.accentOnBackground)
        #expect(values["accent_on_foreground"] == theme.accentOnForeground)
        #expect(values["cmux_app"] == "1")
    }

    @MainActor
    @Test("app web appearance and product accent follow the Ghostty background")
    func appWebAppearanceAndProductAccentFollowGhosttyBackground() throws {
        let darkSnapshot = AppWebThemeSnapshot.resolved(
            backgroundColor: try #require(NSColor(hex: "#101010")),
            foregroundColor: try #require(NSColor(hex: "#F0F0F0"))
        )
        let lightSnapshot = AppWebThemeSnapshot.resolved(
            backgroundColor: try #require(NSColor(hex: "#F0F0F0")),
            foregroundColor: try #require(NSColor(hex: "#101010"))
        )

        #expect(darkSnapshot.appearance == "dark")
        #expect(darkSnapshot.background == "#101010")
        #expect(darkSnapshot.foreground == "#F0F0F0")
        #expect(darkSnapshot.accent == "#0091FF")
        #expect(lightSnapshot.appearance == "light")
        #expect(lightSnapshot.background == "#F0F0F0")
        #expect(lightSnapshot.foreground == "#101010")
        #expect(lightSnapshot.accent == "#0088FF")
        #expect(darkSnapshot.accentOnBackground == "#0091FF")
        #expect(darkSnapshot.accentOnForeground != darkSnapshot.accent)
        #expect(lightSnapshot.accentOnBackground != lightSnapshot.accent)
        #expect(lightSnapshot.accentOnForeground == "#0088FF")
    }

    @MainActor
    @Test("app web theme serializes translucent native colors as opaque RGB")
    func appWebThemeSerializesTranslucentNativeColorsAsOpaqueRGB() {
        let snapshot = AppWebThemeSnapshot.resolved(
            backgroundColor: NSColor(
                srgbRed: 17.0 / 255.0,
                green: 34.0 / 255.0,
                blue: 51.0 / 255.0,
                alpha: 0.25
            ),
            foregroundColor: NSColor(
                srgbRed: 221.0 / 255.0,
                green: 238.0 / 255.0,
                blue: 255.0 / 255.0,
                alpha: 0.5
            )
        )

        #expect(snapshot.background == "#112233")
        #expect(snapshot.foreground == "#DDEEFF")
    }

    @MainActor
    @Test("app web theme JavaScript updates every shared theme variable")
    func appWebThemeJavaScriptUpdatesEverySharedThemeVariable() throws {
        let theme = AppWebThemeSnapshot(
            appearance: "light",
            background: "#FAFAFA",
            foreground: "#171717",
            accent: "#0088FF"
        )
        let browserTheme = theme.browserTheme
        let script = try #require(browserTheme.applyingJavaScript())

        #expect(script.contains("[data-cmux-app-theme]"))
        #expect(script.contains("--ghostty-background"))
        #expect(script.contains("--ghostty-foreground"))
        #expect(script.contains("--cmux-product-blue"))
        #expect(script.contains("--cmux-product-blue-on-background"))
        #expect(script.contains("--cmux-product-blue-on-foreground"))
    }

    @Test("app session handoff pins credentials to production or debug loopback")
    func appSessionHandoffPinsCredentialOrigin() {
        let production = AuthEnvironment.resolvedAppSessionHandoffOrigin(
            environment: ["CMUX_WWW_ORIGIN": "https://attacker.example"],
            isDebugBuild: false
        )
        #expect(production.absoluteString == "https://cmux.com")

        let rejectedDebugRemote = AuthEnvironment.resolvedAppSessionHandoffOrigin(
            environment: ["CMUX_AUTH_WWW_ORIGIN": "https://attacker.example"],
            isDebugBuild: true
        )
        #expect(rejectedDebugRemote.absoluteString == "https://cmux.com")

        let debugLoopback = AuthEnvironment.resolvedAppSessionHandoffOrigin(
            environment: ["CMUX_WWW_ORIGIN": "http://127.0.0.1:4347"],
            isDebugBuild: true
        )
        #expect(debugLoopback.absoluteString == "http://localhost:4347")
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

    @Test("explicit staging is a wholesale set of fixed staging values")
    func explicitStagingWholesaleValues() {
        let staging = "https://cmux-staging.vercel.app"
        #expect(AuthEnvironment.resolvedDefaultWebOrigin(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .staging
        ) == staging)
        #expect(AuthEnvironment.resolvedDefaultAPIBaseURL(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .staging
        ) == staging)
        #expect(AuthEnvironment.resolvedDefaultVMAPIOrigin(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .staging
        ) == staging)
        #expect(AuthEnvironment.resolvedPushAPIBaseURL(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .staging
        ).absoluteString == staging)
        #expect(AuthEnvironment.resolvedIrohBrokerBaseURL(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .staging
        )?.absoluteString == staging)
        #expect(AuthEnvironment.resolvedStackAuthEnvironment(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .staging
        ) == .development)
        #expect(AuthEnvironment.resolvedStackProjectID(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .staging
        ) == "454ecd03-1db2-4050-845e-4ce5b0cd9895")
        #expect(AuthEnvironment.resolvedWebsiteOrigin(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .staging
        ).absoluteString == staging)
        #expect(AuthEnvironment.resolvedAfterSignInOrigin(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .staging
        ).absoluteString == staging)
    }

    @Test("explicit production is a wholesale set matching the unpinned Release lane")
    func explicitProductionWholesaleValues() {
        #expect(AuthEnvironment.resolvedDefaultWebOrigin(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .production
        ) == "https://cmux.com")
        // api.cmux.sh, for Release-lane parity.
        #expect(AuthEnvironment.resolvedDefaultAPIBaseURL(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .production
        ) == "https://api.cmux.sh")
        #expect(AuthEnvironment.resolvedDefaultVMAPIOrigin(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .production
        ) == "https://cmux.com")
        // Push follows the VM-API origin under a choice.
        #expect(AuthEnvironment.resolvedPushAPIBaseURL(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .production
        ).absoluteString == "https://cmux.com")
        #expect(AuthEnvironment.resolvedIrohBrokerBaseURL(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .production
        )?.absoluteString == "https://cmux.com")
        #expect(AuthEnvironment.resolvedStackAuthEnvironment(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .production
        ) == .production)
        #expect(AuthEnvironment.resolvedStackProjectID(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .production
        ) == "9790718f-14cd-4f7e-824d-eaf527a82b82")
        #expect(AuthEnvironment.resolvedWebsiteOrigin(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .production
        ).absoluteString == "https://cmux.com")
    }

    @Test("PIN: an explicit choice beats explicit environment variables, per function")
    func wholesaleBeatsEnvironmentVariablesPerFunction() {
        let staging = "https://cmux-staging.vercel.app"
        // Part F reverses the old layering: the persisted choice used to sit
        // BELOW env (tagged dev builds' LSEnvironment bakes won); a wholesale
        // choice now beats every CMUX_* knob, per function.
        #expect(AuthEnvironment.resolvedDefaultWebOrigin(
            environment: ["CMUX_WWW_ORIGIN": "https://web.example.test"],
            isDebugBuild: false,
            explicitChoice: .staging
        ) == staging)
        #expect(AuthEnvironment.resolvedWebsiteOrigin(
            environment: ["CMUX_WWW_ORIGIN": "https://web.example.test"],
            isDebugBuild: false,
            explicitChoice: .staging
        ).absoluteString == staging)
        #expect(AuthEnvironment.resolvedDefaultAPIBaseURL(
            environment: ["CMUX_API_BASE_URL": "https://api.example.test"],
            isDebugBuild: false,
            explicitChoice: .staging
        ) == staging)
        #expect(AuthEnvironment.resolvedPushAPIBaseURL(
            environment: [
                "CMUX_PUSH_API_BASE_URL": "https://push.example.test",
                "CMUX_VM_API_BASE_URL": "https://vm.example.test",
            ],
            isDebugBuild: false,
            explicitChoice: .staging
        ).absoluteString == staging)
        #expect(AuthEnvironment.resolvedIrohBrokerBaseURL(
            environment: ["CMUX_IROH_BROKER_BASE_URL": "https://broker.example.test"],
            isDebugBuild: false,
            explicitChoice: .staging
        )?.absoluteString == staging)
        #expect(AuthEnvironment.resolvedStackAuthEnvironment(
            environment: ["CMUX_AUTH_ENVIRONMENT": "production"],
            isDebugBuild: false,
            explicitChoice: .staging
        ) == .development)
        #expect(AuthEnvironment.resolvedStackProjectID(
            environment: ["CMUX_STACK_PROJECT_ID": "explicit-project"],
            isDebugBuild: false,
            explicitChoice: .staging
        ) == "454ecd03-1db2-4050-845e-4ce5b0cd9895")
        #expect(AuthEnvironment.resolvedStackPublishableClientKey(
            environment: ["CMUX_STACK_PUBLISHABLE_CLIENT_KEY": "explicit-key"],
            isDebugBuild: false,
            explicitChoice: .staging
        ) == "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g")
        #expect(AuthEnvironment.resolvedAfterSignInOrigin(
            environment: ["CMUX_AUTH_WWW_ORIGIN": "https://auth.example.test"],
            isDebugBuild: false,
            explicitChoice: .staging
        ).absoluteString == staging)
        // The other direction too: explicit production beats a baked
        // development auth environment.
        #expect(AuthEnvironment.resolvedStackAuthEnvironment(
            environment: ["CMUX_AUTH_ENVIRONMENT": "development"],
            isDebugBuild: false,
            explicitChoice: .production
        ) == .production)
    }

    @Test("PIN: an explicit choice beats the DEBUG compile defaults and baked dev ports")
    func wholesaleBeatsDebugDefaults() {
        // Explicit production on a Debug build selects the production Stack
        // channel (the DEBUG development default yields), which also
        // disables dev auto-login for free (it keys on the resolved
        // channel).
        #expect(AuthEnvironment.resolvedStackAuthEnvironment(
            environment: [:],
            isDebugBuild: true,
            explicitChoice: .production
        ) == .production)
        #expect(AuthEnvironment.resolvedStackProjectID(
            environment: [:],
            isDebugBuild: true,
            explicitChoice: .production
        ) == "9790718f-14cd-4f7e-824d-eaf527a82b82")
        #expect(AuthEnvironment.resolvedStackAuthEnvironment(
            environment: [:],
            isDebugBuild: true,
            explicitChoice: .staging
        ) == .development)
        // A tagged Debug build's baked dev port no longer outranks the
        // choice (the old pinning rationale): the whole point of Part F is
        // that the picker works in pinned dev builds.
        #expect(AuthEnvironment.resolvedDefaultWebOrigin(
            environment: ["CMUX_PORT": "4123"],
            isDebugBuild: true,
            explicitChoice: .staging
        ) == "https://cmux-staging.vercel.app")
        #expect(AuthEnvironment.resolvedDefaultWebOrigin(
            environment: ["CMUX_PORT": "4123"],
            isDebugBuild: true,
            explicitChoice: .production
        ) == "https://cmux.com")
        #expect(AuthEnvironment.resolvedDefaultAPIBaseURL(
            environment: ["CMUX_PORT": "4123"],
            isDebugBuild: true,
            explicitChoice: .production
        ) == "https://api.cmux.sh")
    }

    @Test("PIN: the lane (no explicit choice) is byte-identical to the pre-choice defaults")
    func laneResolutionIsByteIdenticalToPreChoiceDefaults() {
        // Release lane defaults.
        #expect(AuthEnvironment.resolvedDefaultWebOrigin(
            environment: [:],
            isDebugBuild: false
        ) == "https://cmux.com")
        #expect(AuthEnvironment.resolvedDefaultAPIBaseURL(
            environment: [:],
            isDebugBuild: false
        ) == "https://api.cmux.sh")
        #expect(AuthEnvironment.resolvedDefaultVMAPIOrigin(
            environment: [:],
            isDebugBuild: false
        ) == "https://cmux.com")
        #expect(AuthEnvironment.resolvedPushAPIBaseURL(
            environment: [:],
            isDebugBuild: false
        ).absoluteString == "https://cmux.com")
        #expect(AuthEnvironment.resolvedIrohBrokerBaseURL(
            environment: [:],
            isDebugBuild: false
        )?.absoluteString == "https://cmux.com")
        #expect(AuthEnvironment.resolvedStackAuthEnvironment(
            environment: [:],
            isDebugBuild: false
        ) == .production)
        // Env vars keep winning on the lane (the dev-rig isolation
        // mechanism).
        #expect(AuthEnvironment.resolvedDefaultWebOrigin(
            environment: ["CMUX_WWW_ORIGIN": "https://web.example.test"],
            isDebugBuild: false
        ) == "https://web.example.test")
        #expect(AuthEnvironment.resolvedDefaultAPIBaseURL(
            environment: ["CMUX_API_BASE_URL": "https://api.example.test"],
            isDebugBuild: false
        ) == "https://api.example.test")
        #expect(AuthEnvironment.resolvedStackProjectID(
            environment: ["CMUX_STACK_PROJECT_ID": "explicit-project"],
            isDebugBuild: false
        ) == "explicit-project")
        #expect(AuthEnvironment.resolvedPushAPIBaseURL(
            environment: ["CMUX_PUSH_API_BASE_URL": "https://push.example.test"],
            isDebugBuild: false
        ).absoluteString == "https://push.example.test")
        // Debug lane defaults: tag-local ports, dev Stack channel, shared
        // staging push/broker.
        #expect(AuthEnvironment.resolvedDefaultWebOrigin(
            environment: ["CMUX_PORT": "4123"],
            isDebugBuild: true
        ) == "http://localhost:4123")
        #expect(AuthEnvironment.resolvedStackAuthEnvironment(
            environment: [:],
            isDebugBuild: true
        ) == .development)
        #expect(AuthEnvironment.resolvedPushAPIBaseURL(
            environment: ["CMUX_VM_API_BASE_URL": "http://localhost:4123"],
            isDebugBuild: true
        ).absoluteString == "https://cmux-staging.vercel.app")
        // Release push follows the VM-API env when set.
        #expect(AuthEnvironment.resolvedPushAPIBaseURL(
            environment: ["CMUX_VM_API_BASE_URL": "https://vm.example.test"],
            isDebugBuild: false
        ).absoluteString == "https://vm.example.test")
    }

    @Test("session handoff pins explicit choices to exactly their fixed origins")
    func sessionHandoffPinsExplicitChoicesToFixedOrigins() {
        #expect(AuthEnvironment.resolvedAppSessionHandoffOrigin(
            environment: [:],
            isDebugBuild: false,
            explicitChoice: .staging
        ).absoluteString == "https://cmux-staging.vercel.app")
        // Env-injected origins never become a credential destination, even
        // with a choice active.
        #expect(AuthEnvironment.resolvedAppSessionHandoffOrigin(
            environment: ["CMUX_WWW_ORIGIN": "https://attacker.example"],
            isDebugBuild: false,
            explicitChoice: .staging
        ).absoluteString == "https://cmux-staging.vercel.app")
        #expect(AuthEnvironment.resolvedAppSessionHandoffOrigin(
            environment: ["CMUX_WWW_ORIGIN": "https://attacker.example"],
            isDebugBuild: false,
            explicitChoice: .production
        ).absoluteString == "https://cmux.com")
        // Without a choice the pin stays on production even when env points
        // at the (publicly known) staging origin.
        #expect(AuthEnvironment.resolvedAppSessionHandoffOrigin(
            environment: ["CMUX_WWW_ORIGIN": "https://cmux-staging.vercel.app"],
            isDebugBuild: false
        ).absoluteString == "https://cmux.com")
        #expect(AuthEnvironment.resolvedAppSessionHandoffOrigin(
            environment: [:],
            isDebugBuild: false
        ).absoluteString == "https://cmux.com")
    }

    @Test("build lane classification: production, staging, and custom bakes")
    func buildLaneClassification() {
        // Unpinned Release: the production lane.
        #expect(AuthEnvironment.resolvedBackendEnvironmentBuildLane(
            environment: [:],
            isDebugBuild: false
        ) == .production)
        // A staging-baked build (device rigs, the STAGING Release app).
        #expect(AuthEnvironment.resolvedBackendEnvironmentBuildLane(
            environment: ["CMUX_WWW_ORIGIN": "https://cmux-staging.vercel.app"],
            isDebugBuild: false
        ) == .staging)
        // A tagged Debug build baked to a localhost origin.
        #expect(AuthEnvironment.resolvedBackendEnvironmentBuildLane(
            environment: [
                "CMUX_WWW_ORIGIN": "http://localhost:4123",
                "CMUX_PORT": "4123",
            ],
            isDebugBuild: true
        ) == .custom(label: "localhost:4123"))
        // An untagged Debug build: cmux.com web fallback but the development
        // Stack channel, so it is NOT the production lane — it gets a custom
        // lane (and thereby the three-position picker).
        #expect(AuthEnvironment.resolvedBackendEnvironmentBuildLane(
            environment: [:],
            isDebugBuild: true
        ) == .custom(label: "cmux.com"))
        // A Release build pinned to prod-auth but a custom web origin.
        #expect(AuthEnvironment.resolvedBackendEnvironmentBuildLane(
            environment: ["CMUX_WWW_ORIGIN": "https://preview.example.test"],
            isDebugBuild: false
        ) == .custom(label: "preview.example.test"))
    }

    @MainActor
    @Test("presence service URL: the explicit choice heads env, defaults key, and build default")
    func presenceServiceURLExplicitChoiceHead() throws {
        let suiteName = "cmuxTests.presenceChoiceHead.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let devWorker = PresenceSettings.debugDefaultServiceURL
        let prodWorker = PresenceSettings.productionServiceURL

        // Explicit staging → the dev worker (the only one that verifies dev
        // Stack tokens), even when the env override AND the defaults tuning
        // knob point elsewhere: a leftover per-build pin must not outlive a
        // switch.
        CMUXBackendEnvironmentOverride.staging.storeChoice(in: defaults)
        defaults.set("https://tuned.example.test", forKey: PresenceSettings.serviceURLKey)
        #expect(PresenceHeartbeatClient.resolvedServiceURL(
            environment: [PresenceSettings.serviceURLEnvKey: "https://env.example.test"],
            defaults: defaults
        )?.absoluteString == devWorker)

        // Explicit production → the production worker, same tiers beaten.
        CMUXBackendEnvironmentOverride.production.storeChoice(in: defaults)
        #expect(PresenceHeartbeatClient.resolvedServiceURL(
            environment: [PresenceSettings.serviceURLEnvKey: "https://env.example.test"],
            defaults: defaults
        )?.absoluteString == prodWorker)

        // No choice: today's tiers, byte-identical — env first, then the
        // defaults key.
        CMUXBackendEnvironmentOverride.clearChoice(in: defaults)
        #expect(PresenceHeartbeatClient.resolvedServiceURL(
            environment: [PresenceSettings.serviceURLEnvKey: "https://env.example.test"],
            defaults: defaults
        )?.absoluteString == "https://env.example.test")
        #expect(PresenceHeartbeatClient.resolvedServiceURL(
            environment: [:],
            defaults: defaults
        )?.absoluteString == "https://tuned.example.test")

        // No choice, no env, no key: the build default.
        defaults.removeObject(forKey: PresenceSettings.serviceURLKey)
        #if DEBUG
        let expectedBuildDefault = devWorker
        #else
        let expectedBuildDefault = prodWorker
        #endif
        #expect(PresenceHeartbeatClient.resolvedServiceURL(
            environment: [:],
            defaults: defaults
        )?.absoluteString == expectedBuildDefault)
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
