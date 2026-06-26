import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileAnalytics
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
@_exported import CmuxMobileShellUI
import CmuxMobileTransport
import Foundation
import OSLog
import SwiftUI

#if os(iOS)
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
    #if os(iOS)
    private let pushCoordinator: MobilePushCoordinator
    private let displaySettings: MobileDisplaySettings
    private let terminalKeyboardCorrectionPreference: MobileTerminalKeyboardCorrectionPreference
    /// The first-run onboarding "seen" flag store, injected into the root view so
    /// it gates the one-time onboarding screen ahead of the never-paired
    /// add-device state.
    private let onboardingStore: MobileOnboardingStore
    #endif
    /// The app-root tailnet detector (behind the shell UI's read-only
    /// observing port), injected into the environment so pairing and
    /// disconnected surfaces can explain a Tailscale-off phone. `nil` on
    /// non-iOS roots, which simply shows no Tailscale guidance.
    private let tailscaleStatusMonitor: (any TailscaleStatusObserving)?
    private let pairedMacStore: (any MobilePairedMacStoring)?
    /// Per-terminal composer drafts for the app session, so an unsent message
    /// survives keyboard dismiss and terminal switches. In-memory only for now;
    /// a disk-backed ``TerminalDraftStoring`` (drafts surviving relaunch) lands
    /// separately and replaces this at the composition root without touching the
    /// shell.
    private let draftStore: any TerminalDraftStoring
    #if DEBUG
    /// The structured diagnostic log injected into the shell store so the DEV
    /// dogfood feedback round-trip can export it. DEBUG-only; `nil` when the app
    /// composition root did not build one.
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
    ///   - terminalKeyboardCorrectionPreference: The app-root terminal keyboard
    ///     correction preference injected into Settings and terminal surfaces.
    ///   - onboardingStore: The app-root first-run onboarding "seen" flag store,
    ///     injected into the root view to gate the one-time onboarding screen.
    ///   - tailscaleStatusMonitor: The app-root tailnet detector, injected into
    ///     the environment for the pairing and disconnected surfaces.
    ///   - diagnosticLog: The structured diagnostic log (DEBUG builds only),
    ///     injected into the shell store for the DEV feedback round-trip.
    public init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        reachability: any ReachabilityProviding,
        analytics: any AnalyticsEmitting,
        pushCoordinator: MobilePushCoordinator,
        displaySettings: MobileDisplaySettings,
        terminalKeyboardCorrectionPreference: MobileTerminalKeyboardCorrectionPreference,
        onboardingStore: MobileOnboardingStore,
        tailscaleStatusMonitor: any TailscaleStatusObserving,
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.runtime = runtime
        self.auth = auth
        self.reachability = reachability
        self.analytics = analytics
        self.pushCoordinator = pushCoordinator
        self.displaySettings = displaySettings
        self.terminalKeyboardCorrectionPreference = terminalKeyboardCorrectionPreference
        self.onboardingStore = onboardingStore
        self.tailscaleStatusMonitor = tailscaleStatusMonitor
        self.pairedMacStore = Self.openPairedMacStore()
        self.draftStore = InMemoryTerminalDraftStore()
        #if DEBUG
        self.diagnosticLog = diagnosticLog
        #endif
    }
    #else
    /// Creates the root scene (non-iOS: no push).
    public init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        reachability: any ReachabilityProviding,
        analytics: any AnalyticsEmitting
    ) {
        self.runtime = runtime
        self.auth = auth
        self.reachability = reachability
        self.analytics = analytics
        self.tailscaleStatusMonitor = nil
        self.pairedMacStore = Self.openPairedMacStore()
        self.draftStore = InMemoryTerminalDraftStore()
        #if DEBUG
        self.diagnosticLog = nil
        #endif
    }
    #endif

    private static func openPairedMacStore() -> (any MobilePairedMacStoring)? {
        do {
            return try MobilePairedMacStore()
        } catch {
            mobileRootSceneLog.error(
                "failed to open paired mac store: \(String(describing: error), privacy: .public)"
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
    private func makeDeviceRegistry() -> DeviceRegistryService? {
        let baseURL = auth.config.apiBaseURL
        guard !baseURL.isEmpty else { return nil }
        let coordinator = auth.coordinator
        return DeviceRegistryService(
            apiBaseURL: baseURL,
            deviceID: DeviceRegistryService.deviceID(),
            tokenSource: DeviceRegistryService.TokenSource(
                accessToken: { try? await coordinator.accessToken() },
                refreshToken: { await coordinator.refreshToken() }
            ),
            teamIDProvider: { await coordinator.resolvedTeamID }
        )
    }

    /// Build the live presence subscription client (the `workers/presence`
    /// Durable Object edge). `nil` when no service URL resolves for this build
    /// (Release without an explicit override), which keeps presence entirely
    /// off; auth mirrors `makeDeviceRegistry()` so the stream always carries
    /// the current session and selected team.
    @MainActor
    private func makePresenceClient() -> PresenceClient? {
        guard let baseURL = PresenceClient.resolvedServiceBaseURL() else { return nil }
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
    /// boundaries must hold even in Release builds where backup is off.
    @MainActor
    private func makeBackedUpPairedMacStore(
        restoreBoundary: PairedMacRestoreBoundary
    ) -> (any MobilePairedMacStoring)? {
        guard let store = pairedMacStore else { return nil }
        let coordinator = auth.coordinator
        let buildScope = MobileIOSBuildScope.current()
        let buildScopedStore: any MobilePairedMacStoring
        if let buildScope {
            buildScopedStore = IOSBuildScopedPairedMacStore(inner: store, scope: buildScope)
        } else {
            buildScopedStore = store
        }
        let scopedStore = TeamScopedPairedMacStore(
            inner: buildScopedStore,
            teamIDProvider: { await coordinator.resolvedTeamID }
        )
        guard MobilePairedMacBackup.resolved().isEnabled,
              let baseURL = PresenceClient.resolvedServiceBaseURL() else {
            return scopedStore
        }
        let client = PairedMacBackupClient(
            serviceBaseURL: baseURL,
            tokenSource: PresenceTokenSource(
                accessToken: { try? await coordinator.accessToken() },
                currentUserID: { await coordinator.currentUser?.id }
            ),
            teamIDProvider: { await coordinator.resolvedTeamID },
            clientScopeProvider: { buildScope?.serializedScope }
        )
        return BackingUpPairedMacStore(
            inner: scopedStore,
            backup: client,
            teamIDProvider: { await coordinator.resolvedTeamID },
            restoreBoundary: restoreBoundary,
            pendingDeleteStore: UserDefaultsPairedMacPendingDeleteStore()
        )
    }

    public var body: some View {
        content
            .environment(auth.coordinator)
            .analytics(analytics)
            .tailscaleStatusMonitor(tailscaleStatusMonitor)
            #if os(iOS)
            .environment(pushCoordinator)
            .environment(displaySettings)
            .environment(terminalKeyboardCorrectionPreference)
            #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        #if DEBUG
        if UITestConfig.workspaceListLayoutPreviewEnabled {
            WorkspaceListLayoutPreviewView()
        } else if ProcessInfo.processInfo.environment["CMUX_ZOOM_STRESS"] == "1" {
            MobileZoomStressView()
        } else {
            CMUXMobileAppView(store: makeStore(), onboardingStore: onboardingStore)
        }
        #else
        CMUXMobileAppView(store: makeStore(), onboardingStore: onboardingStore)
        #endif
        #else
        CMUXMobileAppView(store: makeStore())
        #endif
    }

    @MainActor
    private func makeStore() -> CMUXMobileShellStore {
        let coordinator = auth.coordinator
        let identityProvider = AuthCoordinatorIdentityProvider(coordinator: auth.coordinator)
        let deviceRegistry = makeDeviceRegistry()
        let restoreBoundary = PairedMacRestoreBoundary()
        let backedUpPairedMacStore = makeBackedUpPairedMacStore(restoreBoundary: restoreBoundary)
        let feedbackEmailSubmitter = MobileFeedbackEmailClient(apiBaseURL: auth.config.apiBaseURL)
        let feedbackStampProvider: @MainActor () -> MobileFeedbackStamp = {
            MobileFeedbackStamp.current()
        }
        #if DEBUG
        return CMUXMobileShellStore(
            runtime: runtime,
            pairedMacStore: backedUpPairedMacStore,
            pairedMacRestoreBoundary: restoreBoundary,
            deviceRegistry: deviceRegistry,
            presence: makePresenceClient(),
            identityProvider: identityProvider,
            teamIDProvider: { await coordinator.resolvedTeamID },
            reachability: reachability,
            analytics: analytics,
            diagnosticLog: diagnosticLog,
            feedbackEmailSubmitter: feedbackEmailSubmitter,
            feedbackStampProvider: feedbackStampProvider,
            draftStore: draftStore
        )
        #else
        return CMUXMobileShellStore(
            runtime: runtime,
            pairedMacStore: backedUpPairedMacStore,
            pairedMacRestoreBoundary: restoreBoundary,
            deviceRegistry: deviceRegistry,
            presence: makePresenceClient(),
            identityProvider: identityProvider,
            teamIDProvider: { await coordinator.resolvedTeamID },
            reachability: reachability,
            analytics: analytics,
            feedbackEmailSubmitter: feedbackEmailSubmitter,
            feedbackStampProvider: feedbackStampProvider,
            draftStore: draftStore
        )
        #endif
    }
}
