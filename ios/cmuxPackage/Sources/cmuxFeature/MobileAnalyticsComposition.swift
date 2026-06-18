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
    ///   - session: The URLSession used by the uploader. Defaults to a
    ///     short-timeout session (see ``analyticsSession()``) so a hung analytics
    ///     request cannot keep the emitter's consumer pinned in `upload` for long;
    ///     pass an explicit session in tests.
    public init(
        apiBaseURL: String,
        tokenProvider: any TokenProviding,
        defaults: UserDefaults = .standard,
        session: URLSession? = nil
    ) {
        let uploader = HTTPAnalyticsUploader(
            apiBaseURL: apiBaseURL,
            tokenProvider: AnalyticsTokenProviderBridge(tokenProvider: tokenProvider),
            session: session ?? Self.analyticsSession()
        )
        let consent = UserDefaultsAnalyticsConsentProvider(defaults: defaults)
        // Resolve the per-install id once, here, at the single point that owns
        // analytics. This composition is built before the app shell, so reading
        // the id is also what *mints* it on a fresh install — which is exactly why
        // the `ios_app_first_launch` emit must live here and not in the shell:
        // by the time the shell resolves the id, `created` is already false.
        let resolved = MobileClientIDRepository(defaults: defaults).resolveClientID()
        let anonymousID = resolved.id
        let emitter = AnalyticsEmitter(
            uploader: uploader,
            consent: consent,
            anonymousID: anonymousID
        )
        emitter.setSuperProperties(Self.deviceSuperProperties(anonymousID: anonymousID))
        if resolved.created {
            emitter.capture("ios_app_first_launch", ["client_id": .string(anonymousID)])
        }
        self.emitter = emitter
        self.sessionStore = AnalyticsSessionStore(defaults: defaults)
    }

    /// A short-timeout `URLSession` for analytics uploads.
    ///
    /// Telemetry is best-effort, so a stalled request must fail fast rather than
    /// hold the emitter's consumer in `upload`. A short request timeout bounds the
    /// single-in-flight-upload intake window described on
    /// ``CmuxMobileAnalytics/AnalyticsEmitter``.
    private static func analyticsSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
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
