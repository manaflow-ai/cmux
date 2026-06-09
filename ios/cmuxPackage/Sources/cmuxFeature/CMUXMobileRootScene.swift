import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileAnalytics
import CmuxMobilePairedMac
import CmuxMobileShell
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
    #if os(iOS)
    private let pushCoordinator: MobilePushCoordinator
    private let displaySettings: MobileDisplaySettings
    #endif
    private let pairedMacStore: (any MobilePairedMacStoring)?
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
    ///   - diagnosticLog: The structured diagnostic log (DEBUG builds only),
    ///     injected into the shell store for the DEV feedback round-trip.
    public init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        reachability: any ReachabilityProviding,
        analytics: any AnalyticsEmitting,
        pushCoordinator: MobilePushCoordinator,
        displaySettings: MobileDisplaySettings,
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.runtime = runtime
        self.auth = auth
        self.reachability = reachability
        self.analytics = analytics
        self.pushCoordinator = pushCoordinator
        self.displaySettings = displaySettings
        self.pairedMacStore = Self.openPairedMacStore()
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
        self.pairedMacStore = Self.openPairedMacStore()
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

    public var body: some View {
        content
            .environment(auth.coordinator)
            .analytics(analytics)
            #if os(iOS)
            .environment(pushCoordinator)
            .environment(displaySettings)
            #endif
    }

    @ViewBuilder
    private var content: some View {
        #if canImport(UIKit) && DEBUG
        if ProcessInfo.processInfo.environment["CMUX_ZOOM_STRESS"] == "1" {
            MobileZoomStressView()
        } else {
            CMUXMobileAppView(store: makeStore())
        }
        #else
        CMUXMobileAppView(store: makeStore())
        #endif
    }

    @MainActor
    private func makeStore() -> CMUXMobileShellStore {
        let identityProvider = AuthCoordinatorIdentityProvider(coordinator: auth.coordinator)
        let deviceRegistry = makeDeviceRegistry()
        #if DEBUG
        return CMUXMobileShellStore(
            runtime: runtime,
            pairedMacStore: pairedMacStore,
            deviceRegistry: deviceRegistry,
            identityProvider: identityProvider,
            reachability: reachability,
            analytics: analytics,
            diagnosticLog: diagnosticLog
        )
        #else
        return CMUXMobileShellStore(
            runtime: runtime,
            pairedMacStore: pairedMacStore,
            deviceRegistry: deviceRegistry,
            identityProvider: identityProvider,
            reachability: reachability,
            analytics: analytics
        )
        #endif
    }
}
