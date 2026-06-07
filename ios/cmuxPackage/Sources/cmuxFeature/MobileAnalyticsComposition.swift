import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileAnalytics
import CmuxMobileShellModel
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The analytics composition root for the iOS app.
///
/// Builds the de-singletonized ``CmuxMobileAnalytics/AnalyticsEmitter`` once at
/// startup and exposes it as `any AnalyticsEmitting` for injection into the
/// shell store, push coordinator, and app delegate. It resolves the same web API
/// base URL the auth + push services use (so the analytics proxy honors the
/// `LocalConfig.plist`/`ApiBaseURL` override table), bridges the auth
/// coordinator's tokens, and wires the telemetry opt-out and the per-install
/// anonymous id.
///
/// ```swift
/// let analytics = MobileAnalyticsComposition(
///     apiBaseURL: auth.config.apiBaseURL,
///     tokenProvider: auth.coordinator
/// )
/// // inject analytics.emitter everywhere
/// ```
public struct MobileAnalyticsComposition {
    /// The shared, injected analytics emitter.
    public let emitter: any AnalyticsEmitting
    /// The session store + sessionizer the app shell drives on foreground/background.
    public let sessionStore: AnalyticsSessionStore
    /// The 30-minute-window sessionizer used with ``sessionStore``.
    public let sessionizer = AnalyticsSessionizer()

    /// Builds the analytics graph.
    ///
    /// - Parameters:
    ///   - apiBaseURL: The cmux web API base URL (no trailing slash), from
    ///     ``MobileAuthComposition/config``.
    ///   - tokenProvider: The auth token source (production: `AuthCoordinator`).
    ///   - defaults: Persistence for the opt-out flag, the anonymous client id,
    ///     and sessionization. Defaults to `.standard`; inject a suite in tests.
    ///   - session: The URLSession used by the uploader.
    public init(
        apiBaseURL: String,
        tokenProvider: any TokenProviding,
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        let uploader = HTTPAnalyticsUploader(
            apiBaseURL: apiBaseURL,
            tokenProvider: AnalyticsTokenProviderBridge(tokenProvider: tokenProvider),
            session: session
        )
        let consent = UserDefaultsAnalyticsConsentProvider(defaults: defaults)
        let anonymousID = MobileClientIDRepository(defaults: defaults).clientID
        let emitter = AnalyticsEmitter(
            uploader: uploader,
            consent: consent,
            anonymousID: anonymousID
        )
        emitter.setSuperProperties(Self.deviceSuperProperties(anonymousID: anonymousID))
        self.emitter = emitter
        self.sessionStore = AnalyticsSessionStore(defaults: defaults)
    }

    /// The static device/app super-properties merged onto every event. Sizes and
    /// enums only — no identifiers beyond the anonymous install id.
    private static func deviceSuperProperties(anonymousID: String) -> [String: AnalyticsValue] {
        let info = Bundle.main.infoDictionary
        var props: [String: AnalyticsValue] = ["client_id": .string(anonymousID)]
        if let version = info?["CFBundleShortVersionString"] as? String {
            props["app_version"] = .string(version)
        }
        if let build = info?["CFBundleVersion"] as? String {
            props["build_number"] = .string(build)
        }
        #if canImport(UIKit)
        props["os_version"] = .string(UIDevice.current.systemVersion)
        props["device_model"] = .string(UIDevice.current.model)
        #endif
        return props
    }
}
