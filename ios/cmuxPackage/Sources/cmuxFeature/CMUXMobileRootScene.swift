import CMUXAuthCore
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
    private let personalIrohRouteCatalog: MobileIrohRouteCatalog?
    private let personalIrohDiscovery: (any MobileIrohMacDiscovering)?
    #if os(iOS)
    private let pushCoordinator: MobilePushCoordinator
    private let displaySettings: MobileDisplaySettings
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
    ///   - onboardingStore: The app-root first-run onboarding "seen" flag store,
    ///     injected into the root view to gate the one-time onboarding screen.
    ///   - tailscaleStatusMonitor: The app-root tailnet detector, injected into
    ///     the environment for the pairing and disconnected surfaces.
    ///   - personalIrohRouteCatalog: Authenticated personal-account Iroh routes
    ///     to merge when refreshing paired Macs and listing live candidates.
    ///   - personalIrohDiscovery: Live same-account Mac discovery used before
    ///     presenting QR pairing.
    ///   - signOutHook: Ordered local and remote service teardown for sign-out.
    ///   - diagnosticLog: The privacy-safe structured connection log.
    public init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        reachability: any ReachabilityProviding,
        analytics: any AnalyticsEmitting,
        pushCoordinator: MobilePushCoordinator,
        displaySettings: MobileDisplaySettings,
        onboardingStore: MobileOnboardingStore,
        tailscaleStatusMonitor: any TailscaleStatusObserving,
        personalIrohRouteCatalog: MobileIrohRouteCatalog? = nil,
        personalIrohDiscovery: (any MobileIrohMacDiscovering)? = nil,
        signOutHook: MobileSignOutHook,
        diagnosticLog: DiagnosticLog
    ) {
        self.runtime = runtime
        self.auth = auth
        self.reachability = reachability
        self.analytics = analytics
        self.pushCoordinator = pushCoordinator
        self.displaySettings = displaySettings
        self.onboardingStore = onboardingStore
        self.tailscaleStatusMonitor = tailscaleStatusMonitor
        self.personalIrohRouteCatalog = personalIrohRouteCatalog
        self.personalIrohDiscovery = personalIrohDiscovery
        self.signOutHook = signOutHook
        self.pairedMacStore = Self.openPairedMacStore()
        self.draftStore = InMemoryTerminalDraftStore()
        self.diagnosticLog = diagnosticLog
    }
    #else
    /// Creates the root scene (non-iOS: no push).
    public init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        reachability: any ReachabilityProviding,
        analytics: any AnalyticsEmitting,
        signOutHook: MobileSignOutHook = MobileSignOutHook()
    ) {
        self.runtime = runtime
        self.auth = auth
        self.reachability = reachability
        self.analytics = analytics
        self.signOutHook = signOutHook
        self.personalIrohRouteCatalog = nil
        self.personalIrohDiscovery = nil
        self.tailscaleStatusMonitor = nil
        self.pairedMacStore = Self.openPairedMacStore()
        self.draftStore = InMemoryTerminalDraftStore()
        self.diagnosticLog = nil
    }
    #endif

    private static func openPairedMacStore() -> (any MobilePairedMacStoring)? {
        do {
            #if DEBUG
            if UITestConfig.mockDataEnabled {
                let databaseURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "cmux-uitest-paired-macs-\(UUID().uuidString).sqlite3"
                    )
                return try MobilePairedMacStore(databaseURL: databaseURL)
            }
            #endif
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
    private func makeDeviceRegistry(
        pairedMacStore: (any MobilePairedMacStoring)?
    ) -> (any DeviceRegistryRefreshing)? {
        let baseURL = auth.config.apiBaseURL
        guard !baseURL.isEmpty else { return nil }
        let coordinator = auth.coordinator
        let teamRegistry = DeviceRegistryService(
            apiBaseURL: baseURL,
            deviceID: DeviceRegistryService.deviceID(),
            tokenSource: DeviceRegistryService.TokenSource(
                accessToken: { try? await coordinator.accessToken() },
                refreshToken: { await coordinator.refreshToken() }
            ),
            teamIDProvider: { await coordinator.resolvedTeamID }
        )
        guard let personalIrohRouteCatalog else { return teamRegistry }
        return PersonalIrohDeviceRegistryDecorator(
            base: teamRegistry,
            catalog: personalIrohRouteCatalog,
            knownRoutes: { macDeviceID, instanceTag in
                guard let pairedMacStore else { return nil }
                let userID = await coordinator.currentUser?.id
                let teamID = await coordinator.resolvedTeamID
                let pairedMacs = try? await pairedMacStore.loadAll(
                    stackUserID: userID,
                    teamID: teamID
                )
                let target = cmxCanonicalDeviceID(macDeviceID)
                return pairedMacs?.first(where: {
                    cmxCanonicalDeviceID($0.macDeviceID) == target
                        && $0.instanceTag == instanceTag
                })?.routes
            }
        )
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
              let baseURL = PresenceClient.resolvedServiceBaseURL(
                  isDevelopmentAuthChannel: auth.authEnvironment == .development
              ) else {
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
        applyingRootEnvironment(to: content)
    }

    /// Applies the production root environment to a package-owned alternate
    /// Debug host without widening the app's public composition API.
    @ViewBuilder
    package func applyingRootEnvironment<Content: View>(
        to rootContent: Content
    ) -> some View {
        rootContent
            .environment(auth.coordinator)
            .analytics(analytics)
            .tailscaleStatusMonitor(tailscaleStatusMonitor)
            #if os(iOS)
            .environment(pushCoordinator)
            .environment(displaySettings)
            #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        #if DEBUG
        if UITestConfig.taskComposerPreviewEnabled {
            TaskComposerAccessibilityPreviewView()
        } else if UITestConfig.workspaceListLayoutPreviewEnabled {
            WorkspaceListLayoutPreviewView()
        } else if let recoveryStress = MobileRecoveryStressConfiguration.parse(arguments: ProcessInfo.processInfo.arguments) {
            MobileRecoveryStressView(configuration: recoveryStress)
        } else if ProcessInfo.processInfo.environment["CMUX_ZOOM_STRESS"] == "1" {
            MobileZoomStressView()
        } else if ProcessInfo.processInfo.environment["CMUX_BOTTOM_SCROLL_STRESS"] == "1" {
            MobileBottomScrollStressView()
        } else {
            CMUXMobileAppView(
                store: makeStore(),
                onboardingStore: onboardingStore,
                signOutHook: signOutHook
            )
        }
        #else
        CMUXMobileAppView(
            store: makeStore(),
            onboardingStore: onboardingStore,
            signOutHook: signOutHook
        )
        #endif
        #else
        CMUXMobileAppView(store: makeStore(), signOutHook: signOutHook)
        #endif
    }

    @MainActor
    package func makeStore() -> CMUXMobileShellStore {
        let coordinator = auth.coordinator
        let buildScope = MobileIOSBuildScope.current()
        let buildCompatibilityPolicy = MobileMacBuildCompatibilityPolicy.current(
            buildScope: buildScope
        )
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
        let deviceRegistry = makeDeviceRegistry(pairedMacStore: backedUpPairedMacStore)
        let forgottenMacStore = UserDefaultsPairedMacForgottenStore()
        let feedbackEmailSubmitter = MobileFeedbackEmailClient(apiBaseURL: auth.config.apiBaseURL)
        let feedbackStampProvider: @MainActor () -> MobileFeedbackStamp = {
            MobileFeedbackStamp.current()
        }
        return CMUXMobileShellStore(
            runtime: runtime,
            pairedMacStore: backedUpPairedMacStore,
            buildCompatibilityPolicy: buildCompatibilityPolicy,
            pairedMacRestoreBoundary: restoreBoundary,
            deviceRegistry: deviceRegistry,
            personalIrohDiscovery: personalIrohDiscovery,
            presence: makePresenceClient(),
            identityProvider: identityProvider,
            teamIDProvider: { await coordinator.resolvedTeamID },
            reachability: reachability,
            forgottenMacStore: forgottenMacStore,
            analytics: analytics,
            diagnosticLog: diagnosticLog,
            feedbackEmailSubmitter: feedbackEmailSubmitter,
            feedbackStampProvider: feedbackStampProvider,
            draftStore: draftStore,
            taskTemplateStore: UserDefaultsMobileTaskTemplateStore(defaults: .standard)
        )
    }
}
