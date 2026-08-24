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
import OSLog
import SwiftUI
import cmuxFeature

nonisolated private let appCompositionConnectivityLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "connectivity"
)

/// Holds the de-singletonized graph the `cmuxApp` builds at launch and rebuilds
/// on a live backend-environment switch.
///
/// Owns the mobile runtime, the auth composition (coordinator + push
/// registration), the process-wide reachability monitor, the shared push
/// coordinator, and the mobile display settings. Everything below the app shell
/// receives these by injection instead of reaching for a singleton.
///
/// One process can build more than one root (the backend switch tears the old
/// graph down with ``shutdown()`` and assembles a fresh one), so anything
/// process-global lives in ``ProcessBootstrap`` and is created exactly once.
@MainActor
final class AppCompositionRoot {
    let runtime: CMUXMobileRuntime
    let auth: MobileAuthComposition
    let iroh: MobileIrohRuntimeComposition
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

    /// Mirrors the string debug log into `appLog`; cancelled by ``shutdown()``
    /// so a replaced root's mirror does not double-write lines the new root's
    /// mirror also delivers.
    private var debugLogMirrorTask: Task<Void, Never>? = nil

    /// Everything that must run or exist exactly once per PROCESS, however
    /// many composition roots the live backend switch builds:
    ///
    /// - **`MobileDebugLog` arming**: `.shared` is process-global and lazy;
    ///   the arming append exists so a run that never logs still creates the
    ///   file and crash capture. Arming twice would only append a second
    ///   banner line, but it belongs with launch, not with graph assembly.
    /// - **Crash reporting** (`MobileCrashReporter.startIfEnabled` + its
    ///   `RevocationWatcher`): starts the Sentry SDK and arms a
    ///   process-lifetime consent watcher over `NotificationCenter`. A second
    ///   start would double-arm the watcher and re-enter `SentrySDK.start`.
    /// - **`TransportSentryReporter`**: a passive event sink, but its incident
    ///   policy and sliding-hour log budget are process-level state — a
    ///   rebuilt copy would reset the budget. Its ring export goes through
    ///   ``DiagnosticRingExportRelay`` so captured incidents always attach the
    ///   CURRENT root's diagnostic ring.
    ///
    /// Everything else in the root's initializer is per-graph by design
    /// (defaults-backed stores read the same persisted state again; observers,
    /// tasks, and the event tap are torn down by ``shutdown()``).
    @MainActor
    final class ProcessBootstrap {
        /// Owns the crash reporter's consent-revocation observation for the
        /// life of the process (closes Sentry + purges its stores if telemetry
        /// is turned off mid-session).
        let crashRevocationWatcher = MobileCrashReporter.RevocationWatcher()
        /// Whether the build-level kill switch allowed crash reporting to be
        /// armed (consent gating happens per envelope inside the SDK hooks).
        let crashReportingArmed: Bool
        /// Routes the process-wide reporter's incident attachments to the
        /// current root's diagnostic ring across rebuilds.
        let ringExportRelay = DiagnosticRingExportRelay()
        /// Bridges the diagnostic event stream into Sentry (breadcrumbs,
        /// structured logs, and throttled failure events with the ring export
        /// attached). Delivery no-ops whenever the crash SDK is off (consent
        /// revoked or crash reporting disabled for the build).
        let transportSentryReporter: TransportSentryReporter

        init() {
            #if DEBUG
            // Arm the durable debug log at launch: `.shared` is lazy, and
            // without this a run that never logs would create no file or
            // crash capture.
            MobileDebugLog.shared.append("app launch · process bootstrap")
            #endif
            let telemetryConsent = UserDefaultsAnalyticsConsentProvider(defaults: .standard)
            if AppCompositionRoot.crashReportingEnabled {
                MobileCrashReporter().startIfEnabled(
                    consent: telemetryConsent,
                    revocationWatcher: crashRevocationWatcher
                )
                crashReportingArmed = true
            } else {
                crashReportingArmed = false
            }
            // The reporter checks `SentrySDK.isEnabled` per event, so it
            // respects both the build-level kill switch above and mid-session
            // consent revocation (which closes the SDK) without extra plumbing.
            let relay = ringExportRelay
            transportSentryReporter = TransportSentryReporter(
                role: .mobileClient,
                exportRing: { await relay.export() }
            )
        }
    }

    /// Hands the process-wide Sentry reporter a ring exporter that follows the
    /// CURRENT composition root. Installed synchronously (main actor) by each
    /// root's initializer; read from the reporter's detached capture task.
    @MainActor
    final class DiagnosticRingExportRelay {
        private var exportCurrentRing: (@Sendable () async -> Data)?

        func install(_ exportRing: @escaping @Sendable () async -> Data) {
            exportCurrentRing = exportRing
        }

        nonisolated func export() async -> Data {
            guard let exportRing = await exportCurrentRing else { return Data() }
            return await exportRing()
        }
    }

    /// The once-per-process globals; building a second root reuses them.
    static let processBootstrap = ProcessBootstrap()

    init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        iroh: MobileIrohRuntimeComposition,
        buildCompatibilityPolicy: MobileMacBuildCompatibilityPolicy,
        reachability: any ReachabilityProviding,
        diagnosticLog: DiagnosticLog
    ) {
        let bootstrap = Self.processBootstrap
        self.runtime = runtime
        self.auth = auth
        self.iroh = iroh
        self.buildCompatibilityPolicy = buildCompatibilityPolicy
        self.reachability = reachability
        self.diagnosticLog = diagnosticLog
        let telemetryConsent = UserDefaultsAnalyticsConsentProvider(defaults: .standard)
        let crashReportingEvent: DiagnosticAppEventKind =
            bootstrap.crashReportingArmed && telemetryConsent.isTelemetryEnabled
                ? .crashReportingStarted
                : .crashReportingDisabled
        // Point the process-wide Sentry reporter's incident attachments at
        // THIS root's ring before any event flows through the tap below.
        bootstrap.ringExportRelay.install { [diagnosticLog] in
            await diagnosticLog.export()
        }
        let transportSentryReporter = bootstrap.transportSentryReporter
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
        self.debugLogMirrorTask = Task {
            let sink = MobileDebugLog.shared.sink
            for await line in await sink.lines() {
                guard !Task.isCancelled else { return }
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
        let pushCoordinator = MobilePushCoordinator(
            registration: auth.pushRegistration,
            analytics: analytics.emitter,
            diagnosticLog: diagnosticLog,
            phoneAPIOrigin: auth.config.apiBaseURL,
            notificationSettings: pushNotificationSettings
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

    /// Tears down everything this graph started, in the reverse of interest
    /// order, so a fresh root can be assembled for the new backend environment
    /// (the transaction's quiesce step, after sign-out under the OLD
    /// environment). The isolated `deinit` stays as the backstop for the
    /// pieces it already covered.
    func shutdown() async {
        pushReachabilityTask?.cancel()
        pushReachabilityTask = nil
        featureFlags.stop()
        appLifecycleDiagnostics.stop()
        // Detach the ring tap FIRST so no event reaches the old AppLog or the
        // process-wide Sentry reporter through a graph that is going away; the
        // new root re-installs the tap over its own ring.
        diagnosticLog.setEventTap(nil)
        debugLogMirrorTask?.cancel()
        debugLogMirrorTask = nil
        auth.shutdown()
        await iroh.shutdown()
    }

    isolated deinit {
        pushReachabilityTask?.cancel()
        debugLogMirrorTask?.cancel()
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

extension AppCompositionRoot {
    /// Assembles one complete composition root over the CURRENT persisted
    /// state (`UserDefaults.standard`, `LocalConfig.plist`, Info.plist bakes).
    ///
    /// Called once at launch and again by the backend-switch transaction's
    /// rebuild step, AFTER the override commit, so the auth composition
    /// resolves the just-stored environment. This is the former `cmuxApp`
    /// `static let root` closure body, extracted so a second root can be
    /// built without relaunching (iOS apps must never self-terminate).
    static func assemble() -> AppCompositionRoot {
        let reachability = ReachabilityService()
        let diagnosticLog = DiagnosticLog(
            buildStamp: AppCompositionRoot.diagnosticBuildStamp,
            role: .iosClient
        )
        let auth = MobileAuthComposition(
            reachability: reachability,
            diagnosticLog: diagnosticLog
        )
        let buildCompatibilityPolicy = MobileMacBuildCompatibilityPolicy.current(
            buildScope: MobileIOSBuildScope.current(),
            compatibleMacTags: Bundle.main.object(
                forInfoDictionaryKey: "CMUXCompatibleMacTags"
            ) as? String
        )
        let iroh = MobileIrohRuntimeComposition(
            apiBaseURL: auth.config.apiBaseURL,
            // An explicit persisted environment choice is a WHOLESALE
            // override: the broker resolution must follow it above the baked
            // CMUXIrohBrokerBaseURL, or a switched build would pair against
            // the rig's baked broker while auth talks to the chosen backend.
            backendEnvironmentExplicitChoice: auth.backendEnvironmentExplicitChoice,
            reachability: reachability,
            discoveryCompatibilityPolicy: buildCompatibilityPolicy,
            appNamespace: auth.appNamespace,
            keychainAccessGroup: auth.keychainAccessGroup,
            diagnosticLog: diagnosticLog
        )
        let connectivityInvalidationServiceURL = PresenceClient
            .resolvedServiceBaseURL(
                isDevelopmentAuthChannel: auth.authEnvironment == .development,
                explicitChoice: auth.backendEnvironmentExplicitChoice
            )
        let connectivityInvalidationBaseURL = connectivityInvalidationServiceURL
            .flatMap { URL(string: $0) }
        if connectivityInvalidationBaseURL == nil {
            appCompositionConnectivityLog.error(
                "Connectivity invalidation disabled: presence service URL unavailable"
            )
        }
        iroh.configure(
            auth: auth.coordinator,
            connectivityInvalidationBaseURL: connectivityInvalidationBaseURL
        )

        // `debugLoopback` (127.0.0.1) backs the UI-test mock Mac. Enable it on
        // the simulator and on DEBUG device builds so on-device XCUITests can
        // attach to an in-runner mock host; release device builds keep only
        // real transports.
        #if targetEnvironment(simulator) || DEBUG
        let supportedKinds: [CmxAttachTransportKind] = [.debugLoopback, .tailscale]
        #else
        let supportedKinds: [CmxAttachTransportKind] = [.tailscale]
        #endif
        let networkFactory = CmxNetworkByteTransportFactory(supportedKinds: supportedKinds)
        let fallbackRegistrations = supportedKinds.map { kind in
            CmxRouteTransportFactoryRegistration(kind: kind, factory: networkFactory)
        }
        let registrations = [
            CmxRouteTransportFactoryRegistration(
                kind: .iroh,
                factory: iroh.transportFactory
            ),
        ] + fallbackRegistrations
        let transportFactory: CmxRouteTransportFactory
        do {
            transportFactory = try CmxRouteTransportFactory(registrations)
        } catch {
            preconditionFailure("Invalid mobile transport registrations: \(error)")
        }

        let runtime = CMUXMobileRuntime(
            transportFactory: transportFactory,
            stackAccessTokenProvider: CMUXMobileRuntime.stackAccessTokenProvider(from: auth.coordinator),
            stackAccessTokenForStatusProvider: CMUXMobileRuntime.stackAccessTokenForStatusProvider(from: auth.coordinator),
            stackAccessTokenForceRefresher: CMUXMobileRuntime.stackAccessTokenForceRefresher(from: auth.coordinator),
            independentEventByteStreamProvider: { request in
                try await iroh.serverEventByteStream(for: request)
            },
            terminalLaneProvider: { request, surfaceID, cursor in
                guard let surfaceUUID = UUID(uuidString: surfaceID) else {
                    throw MobileIrohTerminalLaneError.invalidSurfaceID
                }
                return try await iroh.openTerminalLane(
                    for: request,
                    surfaceID: surfaceUUID,
                    cursor: cursor
                )
            },
            artifactLaneProvider: { request, resourceID, offset in
                try await iroh.openArtifactLane(
                    for: request,
                    resourceID: resourceID,
                    offset: offset
                )
            }
        )

        return AppCompositionRoot(
            runtime: runtime,
            auth: auth,
            iroh: iroh,
            buildCompatibilityPolicy: buildCompatibilityPolicy,
            reachability: reachability,
            diagnosticLog: diagnosticLog
        )
    }
}
