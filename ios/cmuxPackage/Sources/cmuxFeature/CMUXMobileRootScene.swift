import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileAnalytics
import CmuxMobilePairedMac
import CmuxMobileBrowserStream
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
@_exported import CmuxMobileShellUI
import CmuxMobileToast
import CmuxMobileTransport
import Foundation
import OSLog
import SwiftUI

#if canImport(UIKit) && DEBUG
import CmuxMobileTerminal
#endif

private let mobileRootSceneLog = Logger(subsystem: "dev.cmux.ios", category: "mobile-root-scene")

/// Top-level mobile scene root.
///
/// Renders the live cmux mobile UI: a ``CMUXMobileAppView`` backed by a fresh
/// ``CMUXMobileShellStore`` and the injected ``AuthCoordinator``. In DEBUG
/// builds, setting the environment variable `CMUX_ZOOM_STRESS=1` instead mounts
/// the terminal zoom-stress repro harness (`MobileZoomStressView`).
///
/// The composition root (`cmuxApp`) builds the ``CMUXMobileRuntime`` and the
/// ``MobileAuthComposition`` and hands them here. The scene injects the
/// coordinator into the SwiftUI environment so views consume it through
/// `@Environment` instead of `AuthManager.shared`.
public struct CMUXMobileRootScene: View {
    private let runtime: CMUXMobileRuntime
    private let auth: MobileAuthComposition
    private let reachability: any ReachabilityProviding
    private let analytics: any AnalyticsEmitting
    package let signOutHook: MobileSignOutHook
    /// The process-wide Mac-instance admission policy.
    private let buildCompatibilityPolicy: MobileMacBuildCompatibilityPolicy
    #if os(iOS)
    private let pushCoordinator: MobilePushCoordinator
    private let displaySettings: MobileDisplaySettings
    private let featureFlags: MobileFeatureFlags
    /// The user's Auto-Connect vs Tailscale connection-method choice, shared by
    /// the shell store (dial ordering) and the Settings/onboarding UI.
    private let connectionMethodStore: MobileConnectionMethodStore
    /// The one-time Auto-Connect migration eligibility and acknowledgement.
    private let autoConnectMigrationStore: MobileAutoConnectMigrationStore
    /// The first-run onboarding "seen" flag store, injected into the root view so
    /// it gates the one-time onboarding screen ahead of the never-paired
    /// add-device state.
    package let onboardingStore: MobileOnboardingStore
    #endif
    /// The app-root tailnet detector (behind the shell UI's read-only
    /// observing port), injected into the environment so pairing and
    /// disconnected surfaces can explain a Tailscale-off phone. `nil` on
    /// non-iOS roots, which simply shows no Tailscale guidance.
    private let tailscaleStatusMonitor: (any TailscaleStatusObserving)?
    private let pairedMacStore: (any MobilePairedMacStoring)?
    /// The app-wide toast presenter, hosted at this root so toasts float over
    /// every screen (including sheets) and any descendant can present through
    /// `@Environment(ToastCenter.self)`.
    @State private var toastCenter: ToastCenter
    #if os(iOS)
    /// What's New state (binary catalog visibility via the remote list,
    /// remote announcements, acknowledgement marker), hosted at this root so
    /// the shell's one-time sheet and Settings > What's New share one fetch
    /// and one cache through `@Environment(MobileWhatsNewCenter.self)`.
    @State private var whatsNewCenter: MobileWhatsNewCenter
    /// Exchanges the native Stack session for cmux web session cookies so
    /// in-app webviews (What's New web pages) render as the signed-in user.
    /// Injected as a plain environment value through
    /// `\.mobileWebAppSession`.
    private let webAppSession: MobileWebAppSessionBroker
    #endif
    /// Per-terminal composer drafts for the app session, so an unsent message
    /// survives keyboard dismiss and terminal switches. In-memory only for now;
    /// a disk-backed ``TerminalDraftStoring`` (drafts surviving relaunch) lands
    /// separately and replaces this at the composition root without touching the
    /// shell.
    private let draftStore: any TerminalDraftStoring
    /// The bounded privacy-safe diagnostic log shared by the production shell
    /// store and the in-app diagnostics exporter.
    #if os(iOS)
    private let diagnosticLog: DiagnosticLog
    #else
    private let diagnosticLog: DiagnosticLog?
    #endif

    #if os(iOS)
    /// Creates the root scene.
    /// - Parameters:
    ///   - runtime: The mobile runtime that backs the shell store.
    ///   - auth: The constructed auth graph (coordinator + push registration).
    ///   - reachability: The process-wide reachability monitor, injected into
    ///     the shell store (already used to build `auth`).
    ///   - analytics: The app-root analytics emitter, injected into the store.
    ///   - pushCoordinator: The app-root push coordinator (shared with the app
    ///     delegate) injected into the environment.
    ///   - displaySettings: The app-root mobile display settings injected into
    ///     the environment (drives workspace-title wrapping).
    ///   - featureFlags: The live PostHog-backed mobile feature flags.
    ///   - connectionMethodStore: The shared Auto-Connect vs Tailscale choice
    ///     used by both connection routing and Settings.
    ///   - autoConnectMigrationStore: The versioned, one-time migration
    ///     eligibility and acknowledgement injected into the root view.
    ///   - onboardingStore: The app-root first-run onboarding "seen" flag store,
    ///     injected into the root view to gate the one-time onboarding screen.
    ///   - tailscaleStatusMonitor: The app-root tailnet detector, injected into
    ///     the environment for the pairing and disconnected surfaces.
    ///   - buildCompatibilityPolicy: Shared Mac-instance admission policy used
    ///     by persistence and connection validation.
    ///   - signOutHook: Ordered local and remote service teardown for sign-out.
    ///   - diagnosticLog: The privacy-safe structured connection log.
    public init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        reachability: any ReachabilityProviding,
        analytics: any AnalyticsEmitting,
        pushCoordinator: MobilePushCoordinator,
        displaySettings: MobileDisplaySettings,
        featureFlags: MobileFeatureFlags,
        connectionMethodStore: MobileConnectionMethodStore,
        autoConnectMigrationStore: MobileAutoConnectMigrationStore,
        onboardingStore: MobileOnboardingStore,
        tailscaleStatusMonitor: any TailscaleStatusObserving,
        buildCompatibilityPolicy: MobileMacBuildCompatibilityPolicy,
        signOutHook: MobileSignOutHook,
        diagnosticLog: DiagnosticLog
    ) {
        self.runtime = runtime
        self.auth = auth
        self.reachability = reachability
        self.analytics = analytics
        self.pushCoordinator = pushCoordinator
        self.displaySettings = displaySettings
        self.featureFlags = featureFlags
        self.connectionMethodStore = connectionMethodStore
        self.autoConnectMigrationStore = autoConnectMigrationStore
        self.onboardingStore = onboardingStore
        self.tailscaleStatusMonitor = tailscaleStatusMonitor
        self.buildCompatibilityPolicy = buildCompatibilityPolicy
        self.signOutHook = signOutHook
        self.pairedMacStore = Self.openPairedMacStore(diagnosticLog: diagnosticLog)
        self.draftStore = InMemoryTerminalDraftStore()
        self.diagnosticLog = diagnosticLog
        _toastCenter = State(initialValue: ToastCenter(diagnosticLog: diagnosticLog))
        _whatsNewCenter = State(
            initialValue: MobileWhatsNewCenter(apiBaseURL: auth.config.apiBaseURL)
        )
        webAppSession = MobileWebAppSessionBroker(
            tokens: auth.coordinator,
            apiBaseURL: auth.config.apiBaseURL,
            projectID: auth.config.stack.projectId
        )
    }
    #else
    /// Creates the root scene (non-iOS: no push).
    public init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        reachability: any ReachabilityProviding,
        analytics: any AnalyticsEmitting,
        buildCompatibilityPolicy: MobileMacBuildCompatibilityPolicy,
        signOutHook: MobileSignOutHook = MobileSignOutHook()
    ) {
        self.runtime = runtime
        self.auth = auth
        self.reachability = reachability
        self.analytics = analytics
        self.signOutHook = signOutHook
        self.buildCompatibilityPolicy = buildCompatibilityPolicy
        self.tailscaleStatusMonitor = nil
        self.pairedMacStore = Self.openPairedMacStore(diagnosticLog: nil)
        self.draftStore = InMemoryTerminalDraftStore()
        self.diagnosticLog = nil
        _toastCenter = State(initialValue: ToastCenter())
    }
    #endif

    private static func openPairedMacStore(
        diagnosticLog: DiagnosticLog?
    ) -> (any MobilePairedMacStoring)? {
        do {
            #if DEBUG
            if UITestConfig.mockDataEnabled {
                // Manual-pair UI tests can relaunch the app after connecting.
                // Their injected device name is unique to one test invocation
                // and survives that relaunch, while every other mock launch
                // stays isolated. Ports can be reused by later runner jobs.
                let storeID = UITestConfig.addDeviceName.flatMap { name in
                    guard UITestConfig.addDevicePort != nil,
                          name.hasPrefix("manual-") else { return nil }
                    return name
                } ?? UUID().uuidString
                let databaseURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "cmux-uitest-paired-macs-\(storeID).sqlite3"
                    )
                let store = try MobilePairedMacStore(databaseURL: databaseURL)
                diagnosticLog?.recordAppEvent(.pairedMacStoreOpened)
                return store
            }
            #endif
            let store = try MobilePairedMacStore()
            diagnosticLog?.recordAppEvent(.pairedMacStoreOpened)
            return store
        } catch {
            mobileRootSceneLog.error(
                "failed to open paired mac store: \(String(describing: error), privacy: .public)"
            )
            diagnosticLog?.recordAppEvent(
                .pairedMacStoreOpenFailed,
                failure: DiagnosticFailureKind.classify(error)
            )
            return nil
        }
    }

    /// Build the team-scoped device-registry client over the auth coordinator.
    ///
    /// Tokens and the target team are read live through the coordinator so the
    /// registry call always uses the current session and selected team. The
    /// service is failure-tolerant, so a missing API base URL or a registry
    /// outage simply means reconnect falls back to local paired-Mac routes.
    @MainActor
    private func makeDeviceRegistry() -> (any DeviceRegistryRefreshing)? {
        let baseURL = auth.config.apiBaseURL
        guard !baseURL.isEmpty, let appNamespace = auth.appNamespace else {
            return nil
        }
        let coordinator = auth.coordinator
        let deviceWitness = DeviceRegistryService.currentDeviceWitness()
        let teamRegistry = DeviceRegistryService(
            apiBaseURL: baseURL,
            deviceID: appNamespace.deviceRegistryDeviceID(
                keychainAccessGroup: auth.keychainAccessGroup,
                deviceWitness: deviceWitness,
                evidence: KeychainIdentityEvidenceProbe()
            ),
            tokenSource: DeviceRegistryService.TokenSource(
                accessToken: { try? await coordinator.accessToken() },
                refreshToken: { await coordinator.refreshToken() }
            ),
            teamIDProvider: { await coordinator.resolvedTeamID }
        )
        return teamRegistry
    }

    /// Build the live presence subscription client (the `workers/presence`
    /// Durable Object edge). `nil` when no service URL resolves for this build
    /// (Release without an explicit override), which keeps presence entirely
    /// off; auth mirrors `makeDeviceRegistry()` so the stream always carries
    /// the current session and selected team.
    @MainActor
    private func makePresenceClient() -> PresenceClient? {
        // Presence follows the resolved auth channel so each worker can verify
        // the token. Build compatibility filters the returned Mac instances.
        guard let baseURL = PresenceClient.resolvedServiceBaseURL(
            isDevelopmentAuthChannel: auth.authEnvironment == .development
        ) else { return nil }
        let coordinator = auth.coordinator
        return PresenceClient(
            serviceBaseURL: baseURL,
            tokenSource: PresenceTokenSource(
                accessToken: { try? await coordinator.accessToken() }
            ),
            teamIDProvider: { await coordinator.resolvedTeamID }
        )
    }

    /// Wrap the local paired-Mac store with selected-team scoping, and then add
    /// the DO-backup decorator when `mobilePairedMacBackup` is on and a presence
    /// service URL resolves. Team scoping is unconditional: selected-team
    /// boundaries must hold even when backup is off.
    @MainActor
    private func makeBackedUpPairedMacStore(
        restoreBoundary: PairedMacRestoreBoundary,
        buildScope: MobileIOSBuildScope?,
        buildCompatibilityPolicy: MobileMacBuildCompatibilityPolicy
    ) -> (any MobilePairedMacStoring)? {
        guard let store = pairedMacStore else { return nil }
        let coordinator = auth.coordinator
        let buildScopedStore: any MobilePairedMacStoring
        if let buildScope {
            buildScopedStore = IOSBuildScopedPairedMacStore(inner: store, scope: buildScope)
        } else {
            buildScopedStore = store
        }
        let scopedStore = TeamScopedPairedMacStore(
            inner: buildCompatibilityPolicy.scoping(buildScopedStore),
            teamIDProvider: { await coordinator.resolvedTeamID }
        )
        guard MobilePairedMacBackup.resolved().isEnabled,
              let appNamespace = auth.appNamespace,
              let baseURL = PresenceClient.resolvedServiceBaseURL(
                  isDevelopmentAuthChannel: auth.authEnvironment == .development
              ) else {
            return scopedStore
        }
        let legacyScope = appNamespace.legacyBackupScope
        let legacyClientScopeProvider: (@Sendable () async -> String?)?
        if let legacyScope {
            let legacyScopeHeader = legacyScope.headerValue
            legacyClientScopeProvider = { @Sendable in legacyScopeHeader }
        } else {
            legacyClientScopeProvider = nil
        }
        let client = PairedMacBackupClient(
            serviceBaseURL: baseURL,
            tokenSource: PresenceTokenSource(
                accessToken: { try? await coordinator.accessToken() },
                currentUserID: { await coordinator.currentUser?.id }
            ),
            teamIDProvider: { await coordinator.resolvedTeamID },
            clientScopeProvider: { appNamespace.serverScope },
            legacyClientScopeProvider: legacyClientScopeProvider
        )
        return BackingUpPairedMacStore(
            inner: scopedStore,
            backup: client,
            teamIDProvider: { await coordinator.resolvedTeamID },
            restoreBoundary: restoreBoundary,
            pendingDeleteStore: UserDefaultsPairedMacPendingDeleteStore(),
            backupTeamStore: UserDefaultsPairedMacBackupTeamStore(),
            diagnosticLog: diagnosticLog
        )
    }

    public var body: some View {
        applyingRootEnvironment(to: content)
    }

    /// Applies the production root environment to a package-owned alternate
    /// Debug host without widening the app's public composition API.
    @ViewBuilder
    package func applyingRootEnvironment<Content: View>(
        to rootContent: Content
    ) -> some View {
        rootContent
            // App-wide toast layer: every root host gets the presentation
            // window and the ToastCenter environment.
            .toastHost(toastCenter, haptics: displaySettings.haptics)
            .environment(auth.coordinator)
            .analytics(analytics)
            .environment(\.mobileDiagnosticLog, diagnosticLog)
            .tailscaleStatusMonitor(tailscaleStatusMonitor)
            #if os(iOS)
            .environment(pushCoordinator)
            .environment(displaySettings)
            .terminalFilesChipEnabled(featureFlags.terminalFilesChipEnabled)
            .keyboardDockRebuildRevertEnabled(featureFlags.keyboardDockRebuildRevertEnabled)
            .environment(connectionMethodStore)
            .environment(autoConnectMigrationStore)
            .environment(whatsNewCenter)
            .environment(\.mobileWebAppSession, webAppSession)
            #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        #if DEBUG
        if UITestConfig.taskComposerPreviewEnabled {
            TaskComposerAccessibilityPreviewView()
        } else if UITestConfig.notificationFeedPreviewEnabled {
            NotificationFeedPreviewView()
        } else if UITestConfig.workspaceListLayoutPreviewEnabled {
            WorkspaceListLayoutPreviewView()
        } else if let recoveryStress = MobileRecoveryStressConfiguration.parse(arguments: ProcessInfo.processInfo.arguments) {
            MobileRecoveryStressView(configuration: recoveryStress)
        } else if ProcessInfo.processInfo.environment["CMUX_ZOOM_STRESS"] == "1" {
            MobileZoomStressView()
        } else if ProcessInfo.processInfo.environment["CMUX_BOTTOM_SCROLL_STRESS"] == "1" {
            MobileBottomScrollStressView()
        } else if ProcessInfo.processInfo.environment["CMUX_TOAST_GALLERY"] == "1" {
            ToastGalleryView()
        } else {
            makeMobileAppView()
        }
        #else
        makeMobileAppView()
        #endif
        #else
        makeMobileAppView()
        #endif
    }

    @MainActor
    private func makeMobileAppView() -> CMUXMobileAppView {
        let browserStreamStore = BrowserStreamStore()
        let simulatorStreamStore = MobileSimulatorStreamStore()
        #if os(iOS)
        return CMUXMobileAppView(
            store: makeStore(
                browserStreamEvents: browserStreamStore,
                simulatorStreamStore: simulatorStreamStore
            ),
            browserStreamStore: browserStreamStore,
            simulatorStreamStore: simulatorStreamStore,
            onboardingStore: onboardingStore,
            signOutHook: signOutHook
        )
        #else
        return CMUXMobileAppView(
            store: makeStore(
                browserStreamEvents: browserStreamStore,
                simulatorStreamStore: simulatorStreamStore
            ),
            browserStreamStore: browserStreamStore,
            simulatorStreamStore: simulatorStreamStore,
            signOutHook: signOutHook
        )
        #endif
    }

    @MainActor
    package func makeStore(
        browserStreamEvents: (any BrowserStreamEventReceiving)? = nil,
        simulatorStreamStore: MobileSimulatorStreamStore? = nil
    ) -> CMUXMobileShellStore {
        let coordinator = auth.coordinator
        let buildScope = MobileIOSBuildScope.current()
        let identityProvider = AuthCoordinatorIdentityProvider(
            coordinator: auth.coordinator,
            isDevelopmentAuthEnvironment: auth.authEnvironment == .development
        )
        let restoreBoundary = PairedMacRestoreBoundary()
        let backedUpPairedMacStore = makeBackedUpPairedMacStore(
            restoreBoundary: restoreBoundary,
            buildScope: buildScope,
            buildCompatibilityPolicy: buildCompatibilityPolicy
        )
        let deviceRegistry = makeDeviceRegistry()
        let hiddenMacStore = UserDefaultsPairedMacHiddenStore()
        let feedbackEmailSubmitter = MobileFeedbackEmailClient(apiBaseURL: auth.config.apiBaseURL)
        let feedbackStampProvider: @MainActor () -> MobileFeedbackStamp = {
            MobileFeedbackStamp.current()
        }
        return CMUXMobileShellStore(
            runtime: runtime,
            pairedMacStore: backedUpPairedMacStore,
            connectionMethodStore: connectionMethodStore,
            buildCompatibilityPolicy: buildCompatibilityPolicy,
            pairedMacRestoreBoundary: restoreBoundary,
            deviceRegistry: deviceRegistry,
            presence: makePresenceClient(),
            identityProvider: identityProvider,
            teamIDProvider: { await coordinator.resolvedTeamID },
            reachability: reachability,
            hiddenMacStore: hiddenMacStore,
            analytics: analytics,
            diagnosticLog: diagnosticLog,
            feedbackEmailSubmitter: feedbackEmailSubmitter,
            feedbackStampProvider: feedbackStampProvider,
            draftStore: draftStore,
            taskTemplateStore: UserDefaultsMobileTaskTemplateStore(
                defaults: .standard,
                diagnosticLog: diagnosticLog
            ),
            browserStreamEvents: browserStreamEvents,
            simulatorStreamStore: simulatorStreamStore
        )
    }
}
