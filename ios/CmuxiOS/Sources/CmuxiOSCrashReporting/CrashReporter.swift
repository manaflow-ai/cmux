public import CMUXMobileCore
import CmuxSentryReporting
public import Foundation
import Sentry

/// Sentry crash, hang and error reporting under the shared telemetry consent
/// (plans/cmux-next/ios-next/c16-platform.md section 3).
///
/// The SDK runs only while `consent.isTelemetryEnabled` is true and never in
/// test runs. Every event and breadcrumb re-reads consent and passes the
/// shared `SentryEventScrubber` before it leaves the device. Session replay,
/// swizzling, automatic network capture and auto breadcrumbs stay off.
@MainActor
public final class CrashReporter {
    private let consent: any AnalyticsConsentProviding
    private let buildAllowsReporting: Bool
    private let environment: [String: String]
    private let notificationCenter: NotificationCenter
    private let start: (Options) -> Void
    private let close: () -> Void
    private var observer: (any NSObjectProtocol)?
    public private(set) var isRunning = false

    /// - Parameter buildAllowsReporting: the build's `CMUXCrashReportingEnabled`
    ///   (release tooling sets it); false never starts the SDK.
    public init(
        consent: any AnalyticsConsentProviding,
        buildAllowsReporting: Bool = CrashReporter.buildSetting(Bundle.main),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        notificationCenter: NotificationCenter = .default,
        start: @escaping (Options) -> Void = { SentrySDK.start(options: $0) },
        close: @escaping () -> Void = { SentrySDK.close() }
    ) {
        self.consent = consent
        self.buildAllowsReporting = buildAllowsReporting
        self.environment = environment
        self.notificationCenter = notificationCenter
        self.start = start
        self.close = close
    }

    /// Starts reporting when consent allows and follows consent changes for
    /// the process lifetime (one defaults observer; no timer).
    public func activate() {
        guard observer == nil, buildAllowsReporting, !Self.isTestRun(environment) else { return }
        observer = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyConsent() }
        }
        applyConsent()
    }

    /// Mirrors one diagnostic line as a breadcrumb; dropped while the SDK is
    /// off. Callable from any thread.
    public nonisolated static func breadcrumb(level: String, category: String, message: String) {
        guard SentrySDK.isEnabled else { return }
        let crumb = Breadcrumb(level: Self.sentryLevel(level), category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    func applyConsent() {
        let enabled = consent.isTelemetryEnabled
        if enabled, !isRunning {
            start(makeOptions())
            isRunning = true
        } else if !enabled, isRunning {
            close()
            isRunning = false
        }
    }

    /// The Sentry options, without starting the SDK.
    public func makeOptions() -> Options {
        let options = Options()
        options.dsn = Self.dsn
        #if DEBUG
        options.environment = "ios-next-development"
        #else
        options.environment = "ios-next-production"
        #endif
        options.debug = false
        options.tracesSampleRate = 0
        options.sendDefaultPii = false
        options.attachStacktrace = true
        options.enableCaptureFailedRequests = false
        options.enableWatchdogTerminationTracking = true
        options.enableAppHangTracking = true
        options.appHangTimeoutInterval = 8
        // URLSession requests carry auth; injected trace headers cannot be
        // scrubbed by beforeSend, so swizzling and network capture stay off.
        options.enableSwizzling = false
        options.enableNetworkTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableAutoBreadcrumbTracking = false
        options.tracePropagationTargets = []
        options.enableAutoSessionTracking = true
        // Replay stays off until D3 lists the Metal and video surfaces to mask.
        options.sessionReplay.onErrorSampleRate = 0
        options.sessionReplay.sessionSampleRate = 0
        #if canImport(MetricKit) && os(iOS)
        options.enableMetricKit = true
        #endif
        let consent = self.consent
        let scrubber = SentryEventScrubber()
        options.beforeSend = { event in consent.isTelemetryEnabled ? scrubber.scrub(event) : nil }
        options.beforeBreadcrumb = { crumb in consent.isTelemetryEnabled ? scrubber.scrub(crumb) : nil }
        return options
    }

    /// `CMUXCrashReportingEnabled` from Info.plist: NO, false or 0 disable.
    public nonisolated static func buildSetting(_ bundle: Bundle) -> Bool {
        let raw = bundle.object(forInfoDictionaryKey: "CMUXCrashReportingEnabled")
        if let flag = raw as? Bool { return flag }
        guard let text = (raw as? String)?.lowercased() else { return true }
        return !["no", "false", "0"].contains(text)
    }

    nonisolated static func isTestRun(_ environment: [String: String]) -> Bool {
        let keys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
        if keys.contains(where: { environment[$0] != nil }) { return true }
        return environment.keys.contains { $0.hasPrefix("XCInjectBundle") || $0.hasPrefix("CMUX_UITEST_") }
    }

    private nonisolated static func sentryLevel(_ level: String) -> SentryLevel {
        switch level {
        case "error": .error
        case "warning": .warning
        case "debug": .debug
        default: .info
        }
    }

    /// The dedicated cmux-ios Sentry project (shared with the shipping app;
    /// the environment name separates the new shell's events).
    private nonisolated static let dsn =
        "https://834d19a3077c4adbff534dca1e93de4f@o4507547940749312.ingest.us.sentry.io/4510604800491520"
}
