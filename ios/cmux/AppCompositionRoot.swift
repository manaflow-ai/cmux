import CMUXMobileCore
import CmuxMobileAnalytics
import CmuxMobileCrashReporting
import CmuxMobileDiagnostics
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTransport
import CmuxSentryReporting
import Foundation
import SwiftUI
import cmuxFeature

/// Holds the de-singletonized graph the `cmuxApp` builds once at launch.
///
/// Owns the mobile runtime, the auth composition (coordinator + push
/// registration), the process-wide reachability monitor, the shared push
/// coordinator, and the mobile display settings. Everything below the app shell
/// receives these by injection instead of reaching for a singleton.
@MainActor
final class AppCompositionRoot {
    let runtime: CMUXMobileRuntime
    let auth: MobileAuthComposition
    let iroh: MobileIrohRuntimeComposition
    /// The irx (from-scratch iroh) composition when its DEBUG flag owns the
    /// `.iroh` route; nil when the legacy runtime is active.
    let irx: MobileIrxRuntimeComposition?
    /// The dor (account Durable Object relay) composition when its gate owns
    /// the `.iroh` route — the default; nil when irx or legacy is active.
    let dor: MobileDorRuntimeComposition?
    /// One build-compatibility policy shared by discovery, persistence, and
    /// connection validation. Keeping it here prevents composition paths from
    /// admitting different Mac app instances.
    let buildCompatibilityPolicy: MobileMacBuildCompatibilityPolicy
    let reachability: any ReachabilityProviding
    let pushCoordinator: MobilePushCoordinator
    let signOutHook: MobileSignOutHook
    let analytics: MobileAnalyticsComposition
    let featureFlags: MobileFeatureFlags
    let displaySettings: MobileDisplaySettings
    /// App-lifetime keyboard frame record, injected into the view tree via
    /// `\.mobileKeyboardFrameTracker` so terminal hosts created or reattached
    /// mid-conversation recover keyboard transitions they were not installed
    /// for. Constructed here (not lazily in a view) so its record spans every
    /// host view lifetime.
    let keyboardFrameTracker = MobileKeyboardFrameTracker()
    private var pushReachabilityTask: Task<Void, Never>? = nil
    /// The user's Auto-Connect vs Tailscale connection-method choice, shared by
    /// the shell store (dial ordering) and the Settings/onboarding UI.
    let connectionMethodStore: MobileConnectionMethodStore
    /// One-time BETA migration eligibility, snapshotted before launch writes.
    let autoConnectMigrationStore: MobileAutoConnectMigrationStore
    /// First-run onboarding progress, persisted to `UserDefaults.standard`.
    /// Built with `forceComplete` set when a UI-test mock harness or a dogfood
    /// auto-pair attach URL is active, so neither path is wedged behind the
    /// one-time onboarding screen.
    let onboardingStore: MobileOnboardingStore
    /// The process-wide tailnet detector behind the shell UI's read-only
    /// observing port, injected down so pairing and disconnected surfaces can
    /// explain a Tailscale-off phone.
    let tailscaleStatusMonitor: TailscaleStatusMonitorAdapter
    /// Owns the crash reporter's consent-revocation observation for the life
    /// of the process (closes Sentry + purges its stores if telemetry is
    /// turned off mid-session).
    let crashRevocationWatcher = MobileCrashReporter.RevocationWatcher()

    /// The bounded, structured connection log shared by the Iroh runtime and
    /// mobile shell. It is present in release builds, but its schema accepts
    /// only fixed categories and integer magnitudes, never terminal contents,
    /// credentials, peer identities, addresses, or free-form errors.
    let diagnosticLog: DiagnosticLog

    /// Owns UIKit lifecycle observers and removes them with the app graph.
    private let appLifecycleDiagnostics: MobileAppLifecycleDiagnostics

    /// The consolidated on-disk log pair: `cmux-app.log` (app-wide, including
    /// the mirrored string debug log) and `cmux-network.log` (network
    /// diagnostics). Fed by the diagnostic ring's event tap; always on, since
    /// structured events are privacy-safe by construction.
    let appLog: AppLog

    /// Bridges the diagnostic event stream into Sentry (breadcrumbs, structured
    /// logs, and throttled failure events with the ring export attached). Held
    /// for the process lifetime; delivery no-ops whenever the crash SDK is off
    /// (consent revoked or crash reporting disabled for the build).
    private let transportSentryReporter: TransportSentryReporter

    init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        iroh: MobileIrohRuntimeComposition,
        irx: MobileIrxRuntimeComposition? = nil,
        dor: MobileDorRuntimeComposition? = nil,
        buildCompatibilityPolicy: MobileMacBuildCompatibilityPolicy,
        reachability: any ReachabilityProviding,
        diagnosticLog: DiagnosticLog
    ) {
        #if DEBUG
        // Arm the durable debug log at launch: `.shared` is lazy, and without
        // this a run that never logs would create no file or crash capture.
        MobileDebugLog.shared.append("app launch · composition root initialized")
        #endif

        self.runtime = runtime
        self.auth = auth
        self.iroh = iroh
        self.irx = irx
        self.dor = dor
        self.buildCompatibilityPolicy = buildCompatibilityPolicy
        self.reachability = reachability
        self.diagnosticLog = diagnosticLog
        let telemetryConsent = UserDefaultsAnalyticsConsentProvider(defaults: .standard)
        let crashReportingEvent: DiagnosticAppEventKind
        if Self.crashReportingEnabled {
            MobileCrashReporter().startIfEnabled(
                consent: telemetryConsent,
                revocationWatcher: crashRevocationWatcher
            )
            crashReportingEvent = telemetryConsent.isTelemetryEnabled
                ? .crashReportingStarted
                : .crashReportingDisabled
        } else {
            crashReportingEvent = .crashReportingDisabled
        }
        // The reporter checks `SentrySDK.isEnabled` per event, so it respects
        // both the build-level kill switch above and mid-session consent
        // revocation (which closes the SDK) without extra plumbing.
        let transportSentryReporter = TransportSentryReporter(
            role: .mobileClient,
            exportRing: { [diagnosticLog] in await diagnosticLog.export() }
        )
        self.transportSentryReporter = transportSentryReporter
        let appLog = AppLog(
            appFileURL: AppLog.defaultAppLogFileURL,
            networkFileURL: AppLog.defaultNetworkLogFileURL,
            buildStamp: MobileDebugLog.buildStamp
        )
        self.appLog = appLog
        diagnosticLog.setEventTap { event in
            appLog.ingest(event)
            transportSentryReporter.ingest(event)
        }
        self.appLifecycleDiagnostics = MobileAppLifecycleDiagnostics(
            diagnosticLog: diagnosticLog
        )
        diagnosticLog.recordAppEvent(.appLaunched)
        diagnosticLog.recordAppEvent(crashReportingEvent)
        // Mirror the string debug log into the app log file so one file holds
        // the whole in-app story in wall-clock order. The string sink keeps
        // its own privacy gating (DEBUG always, Release behind the verbose
        // opt-in), so this mirror never widens what gets persisted.
        Task {
            let sink = MobileDebugLog.shared.sink
            for await line in await sink.lines() {
                appLog.mirrorAppLine(line)
            }
        }
        let analytics = MobileAnalyticsComposition(
            apiBaseURL: auth.config.apiBaseURL,
            tokenProvider: auth.coordinator,
            consent: telemetryConsent,
            diagnosticLog: diagnosticLog
        )
        self.analytics = analytics
        self.featureFlags = MobileFeatureFlags(
            loader: analytics.clientConfig,
            request: analytics.anonymousClientConfigRequest
        )
        #if DEBUG
        let pushNotificationSettings:
            (@MainActor () async -> MobilePushSystemSettings)?
        if UITestConfig.mockDataEnabled {
            // Full-app mock tests run on freshly erased simulators. Keep the
            // real SpringBoard authorization alert out of unrelated UI flows.
            pushNotificationSettings = { .authorizationOnly(.denied) }
        } else {
            pushNotificationSettings = nil
        }
        #else
        let pushNotificationSettings:
            (@MainActor () async -> MobilePushSystemSettings)? = nil
        #endif
        #if DEBUG
        // DEV: a devicectl launch with DEVICECTL_CHILD_CMUX_PRESENCE_BASE_URL
        // persists the isolated-worker override so later env-less cold
        // launches (push wakes) keep resolving it.
        PresenceClient.persistEnvironmentOverrideIfPresent()
        #endif
        // Inline replies relay through the presence worker when the phone
        // cannot deliver directly (a backgrounded app never dials). Same
        // worker origin as the connectivity subscriber, so the account that
        // subscribes is the account whose inbox the Mac sweeps.
        let replyRelayBaseURL = PresenceClient.resolvedServiceBaseURL(
            isDevelopmentAuthChannel: auth.authEnvironment == .development
        ).flatMap { URL(string: $0) }
        let replyRelayAccessToken = CMUXMobileRuntime.stackAccessTokenProvider(
            from: auth.coordinator
        )
        let pushCoordinator = MobilePushCoordinator(
            registration: auth.pushRegistration,
            analytics: analytics.emitter,
            diagnosticLog: diagnosticLog,
            phoneAPIOrigin: auth.config.apiBaseURL,
            notificationSettings: pushNotificationSettings,
            replyRelay: SystemReplyRelayClient(
                serviceBaseURL: replyRelayBaseURL,
                accessToken: { try? await replyRelayAccessToken() }
            )
        )
        self.pushCoordinator = pushCoordinator
        self.signOutHook = MobileSignOutHook {
            let signingOutAccountID = auth.coordinator.currentUser?.id
            let preparation = iroh.beginSignOutPreparation()
            return { accessToken, refreshToken in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await pushCoordinator.unregisterFromServer(
                            accountID: signingOutAccountID,
                            accessToken: accessToken,
                            refreshToken: refreshToken
                        )
                    }
                    group.addTask {
                        await iroh.completeSignOutAfterAuthClear(
                            preparation,
                            accessToken: accessToken,
                            refreshToken: refreshToken
                        )
                    }
                }
                await diagnosticLog.clear()
            }
        }
        // Main's display-settings owner intentionally keeps diagnostics out of
        // the preferences object. The app root still owns the shared log for
        // services that emit lifecycle events, while display preferences use
        // their injected defaults store only.
        self.displaySettings = MobileDisplaySettings()
        // Snapshot raw upgrade eligibility before either current-launch store is
        // constructed. The migration model persists pending/ineligible now and
        // never recomputes after onboarding or Settings writes. UI fixtures use
        // one isolated defaults suite for both pieces of durable state, so a
        // relaunch proves the production persistence path without touching the
        // simulator's normal connection preference.
        let connectionPreferenceDefaults: UserDefaults
        #if DEBUG
        if let fixture = AutoConnectMigrationUITestConfiguration(
            environment: ProcessInfo.processInfo.environment
        ) {
            guard let fixtureDefaults = UserDefaults(suiteName: fixture.defaultsSuiteName) else {
                preconditionFailure("Unable to create Auto-Connect migration UI-test defaults")
            }
            if fixtureDefaults.object(
                forKey: MobileAutoConnectMigrationStore.resolutionKey
            ) == nil {
                if let persistedConnectionMethod = fixture.persistedConnectionMethod {
                    fixtureDefaults.set(
                        persistedConnectionMethod.rawValue,
                        forKey: MobileConnectionMethodStore.methodKey
                    )
                } else {
                    fixtureDefaults.removeObject(
                        forKey: MobileConnectionMethodStore.methodKey
                    )
                }
                // Keep this DEBUG fixture key aligned with the immutable v1
                // schema so the UI test enters through real migration storage.
                let legacyResolutionKey = "dev.cmux.mobile.autoConnectIntroduction.v1"
                if let legacyResolution = fixture.legacyResolution {
                    fixtureDefaults.set(
                        legacyResolution.rawValue,
                        forKey: legacyResolutionKey
                    )
                } else {
                    fixtureDefaults.removeObject(forKey: legacyResolutionKey)
                }
                switch fixture.eligibility {
                case .eligible:
                    fixtureDefaults.set(
                        MobileOnboardingProgress.complete.rawValue,
                        forKey: MobileOnboardingStore.progressKey
                    )
                case .ineligible:
                    fixtureDefaults.removeObject(forKey: MobileOnboardingStore.progressKey)
                }
            }
            connectionPreferenceDefaults = fixtureDefaults
        } else {
            connectionPreferenceDefaults = .standard
        }
        #else
        connectionPreferenceDefaults = .standard
        #endif
        self.autoConnectMigrationStore = MobileAutoConnectMigrationStore(
            defaults: connectionPreferenceDefaults
        )
        self.connectionMethodStore = MobileConnectionMethodStore(
            defaults: connectionPreferenceDefaults,
            diagnosticLog: diagnosticLog
        )
        // Skip first-run onboarding when a UI-test mock harness
        // (`CMUX_UITEST_MOCK_DATA`/XCUITest) or a dogfood auto-pair attach URL is
        // active: those launches expect to land on sign-in / add-device / a live
        // workspace, not behind a manual tap-through. The dedicated onboarding
        // preview remains active so its relaunch test exercises real persistence.
        // `forceComplete` never writes the real install's persisted progress.
        #if DEBUG
        let onboardingPreviewEnabled = UITestConfig.onboardingPreviewEnabled
        #else
        let onboardingPreviewEnabled = false
        #endif
        let bypassOnboarding = (UITestConfig.mockDataEnabled && !onboardingPreviewEnabled)
            || UITestConfig.dogfoodAttachURL != nil
            || UITestConfig.attachURL != nil
        self.onboardingStore = MobileOnboardingStore(
            defaults: .standard,
            forceComplete: bypassOnboarding
        )
        self.tailscaleStatusMonitor = TailscaleStatusMonitorAdapter(monitor: TailscaleStatusMonitor())
        self.pushReachabilityTask = Task { @MainActor [weak pushCoordinator] in
            for await _ in reachability.pathChanges() {
                guard let pushCoordinator, !Task.isCancelled else { return }
                guard await reachability.isOnline else { continue }
                await pushCoordinator.networkDidBecomeReachable()
            }
        }
        // Start auth only after the diagnostic tap is durable. Session restore
        // can complete during launch, and starting earlier would leave its
        // accepted events in the in-memory ring but absent from cmux-app.log.
        auth.start()
        featureFlags.start()
    }

    isolated deinit {
        pushReachabilityTask?.cancel()
        featureFlags.stop()
    }

    /// Bundle-owned build identity used in explicit diagnostic exports.
    /// Values come only from signed app metadata, never user input.
    static var diagnosticBuildStamp: String {
        DiagnosticBuildStamp.make(infoDictionary: Bundle.main.infoDictionary)
    }

    private static var crashReportingEnabled: Bool {
        switch Bundle.main.object(forInfoDictionaryKey: "CMUXCrashReportingEnabled") {
        case let enabled as Bool:
            enabled
        case let enabled as String:
            enabled.caseInsensitiveCompare("NO") != .orderedSame
        default:
            true
        }
    }

    /// The most recent scene phase, so a `.active` transition is classified as a
    /// cold first foreground vs. a warm resume.
    private var hasForegrounded = false
    /// When the current session started, for the best-effort `ios_session_ended`
    /// duration emitted on background.
    private var currentSessionStartedAt: Date?
    /// The id of the session currently in progress, echoed onto `ios_session_ended`.
    private var currentSessionID: String?

    /// Drives the app-lifecycle + sessionization analytics on scene-phase changes.
    ///
    /// On `.active`: resolves the session (cold start or 30-min-gap resume) via
    /// the injected ``CmuxMobileAnalytics/AnalyticsSessionizer`` and persisted
    /// ``CmuxMobileAnalytics/AnalyticsSessionStore``, emitting `ios_session_started`
    /// only when a new session begins, plus an `ios_app_foregrounded` heartbeat.
    /// On `.background`: records the timestamp for the next gap calculation,
    /// emits `ios_app_backgrounded`, and force-flushes queued events before
    /// suspension.
    func handleScenePhase(_ phase: ScenePhase) {
        let emitter = analytics.emitter
        switch phase {
        case .active:
            diagnosticLog.recordAppEvent(.appForegrounded)
            connectionMethodStore.recordConfiguredMethodDiagnostic()
            let isFullForegroundReturn = iroh.didBecomeActive()
            if let dor {
                // Engine warm-up: iOS suspension pauses the leg watchdogs, so
                // a session that died in the background redials now.
                Task { await dor.didBecomeActive() }
            }
            if let irx {
                // Credential freshness re-check + engine warm-up: iOS
                // suspension pauses the autopilot's sleep loop.
                Task { await irx.didBecomeActive() }
            }
            // A notification-permission prompt is itself a transient inactive
            // edge, so readiness still observes every active transition.
            Task { await pushCoordinator.refreshReadiness() }
            guard isFullForegroundReturn else { return }
            featureFlags.refreshOnForeground()
            let now = Date()
            let decision = analytics.sessionizer.resolveForeground(
                now: now,
                lastBackgroundedAt: analytics.sessionStore.lastBackgroundedAt,
                currentSessionID: analytics.sessionStore.currentSessionID
            )
            analytics.sessionStore.setCurrentSessionID(decision.sessionID)
            let launchType = hasForegrounded ? "warm" : "cold"
            currentSessionID = decision.sessionID.uuidString
            if decision.startedNewSession {
                currentSessionStartedAt = now
                emitter.capture("ios_session_started", [
                    "session_id": .string(decision.sessionID.uuidString),
                    "launch_type": .string(launchType),
                ])
            }
            var foregroundProps: [String: AnalyticsValue] = ["launch_type": .string(launchType)]
            if let gap = decision.secondsSinceBackgrounded {
                foregroundProps["seconds_since_backgrounded"] = .int(Int(gap))
            }
            emitter.capture("ios_app_foregrounded", foregroundProps)
            hasForegrounded = true
        case .inactive:
            diagnosticLog.recordAppEvent(.appBecameInactive)
            // The switcher opened; a swipe-kill from here may skip the
            // background transition entirely, so snapshot diagnostics now.
            iroh.archiveDiagnostics()
        case .background:
            diagnosticLog.recordAppEvent(.appBackgrounded)
            iroh.didEnterBackground()
            let now = Date()
            analytics.sessionStore.recordBackgrounded(at: now)
            emitter.capture("ios_app_backgrounded", [:])
            // Best-effort session end on background. iOS may hard-kill the app
            // without a `.background` transition, so this is not guaranteed; the
            // 30-min gap on the next foreground still re-sessionizes correctly.
            if let sessionID = currentSessionID {
                var props: [String: AnalyticsValue] = ["session_id": .string(sessionID)]
                if let startedAt = currentSessionStartedAt {
                    props["session_duration_seconds"] = .int(max(0, Int(now.timeIntervalSince(startedAt))))
                }
                emitter.capture("ios_session_ended", props)
            }
            // Force a flush before the OS may suspend us, so queued events survive.
            Task { await emitter.flush() }
        @unknown default:
            break
        }
    }
}
