import CmuxAuthRuntime
import CmuxMobilePairedMac
import CmuxMobileShell
@_exported import CmuxMobileShellUI
import CmuxMobileTransport
import Foundation
import OSLog
import SwiftUI

#if canImport(UIKit)
import CmuxMobileGhosttyEngine
#endif
#if canImport(UIKit) && DEBUG
import CmuxMobileTerminal
#endif

private let mobileRootSceneLog = Logger(subsystem: "dev.cmux.ios", category: "mobile-root-scene")

/// Top-level mobile scene root.
///
/// Renders the live cmux mobile UI: a ``CMUXMobileAppView`` backed by a fresh
/// ``CMUXMobileShellStore`` and the injected ``AuthCoordinator``. In DEBUG
/// builds, setting the environment variable `CMUX_ZOOM_STRESS=1` instead mounts
/// the terminal zoom-stress repro harness (`MobileZoomStressView`), and
/// `CMUX_LATENCY_PROBE=1` mounts the typing-latency / render-cadence
/// measurement harness (`MobileTerminalLatencyProbeView`).
///
/// The composition root (`cmuxApp`) builds the ``CMUXMobileRuntime`` and the
/// ``MobileAuthComposition`` and hands them here. The scene injects the
/// coordinator into the SwiftUI environment so views consume it through
/// `@Environment` instead of `AuthManager.shared`.
public struct CMUXMobileRootScene: View {
    private let runtime: CMUXMobileRuntime
    private let auth: MobileAuthComposition
    private let reachability: any ReachabilityProviding
    #if os(iOS)
    private let pushCoordinator: MobilePushCoordinator
    /// Root-constructed Ghostty engine provider, injected into the SwiftUI
    /// environment so terminal surfaces resolve the engine without a
    /// singleton.
    private let terminalEngine: GhosttyEngineProvider
    #endif
    private let pairedMacStore: (any MobilePairedMacStoring)?

    #if os(iOS)
    /// Creates the root scene.
    /// - Parameters:
    ///   - runtime: The mobile runtime that backs the shell store.
    ///   - auth: The constructed auth graph (coordinator + push registration).
    ///   - reachability: The process-wide reachability monitor, injected into
    ///     the shell store (already used to build `auth`).
    ///   - pushCoordinator: The app-root push coordinator (shared with the app
    ///     delegate) injected into the environment.
    ///   - terminalEngine: The root-constructed Ghostty engine provider.
    public init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        reachability: any ReachabilityProviding,
        pushCoordinator: MobilePushCoordinator,
        terminalEngine: GhosttyEngineProvider
    ) {
        self.runtime = runtime
        self.auth = auth
        self.reachability = reachability
        self.pushCoordinator = pushCoordinator
        self.terminalEngine = terminalEngine
        self.pairedMacStore = Self.openPairedMacStore()
    }
    #else
    /// Creates the root scene (non-iOS: no push).
    public init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        reachability: any ReachabilityProviding
    ) {
        self.runtime = runtime
        self.auth = auth
        self.reachability = reachability
        self.pairedMacStore = Self.openPairedMacStore()
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

    public var body: some View {
        content
            .environment(auth.coordinator)
            #if os(iOS)
            .environment(pushCoordinator)
            .environment(terminalEngine)
            #endif
    }

    @ViewBuilder
    private var content: some View {
        #if canImport(UIKit) && DEBUG
        if ProcessInfo.processInfo.environment["CMUX_ZOOM_STRESS"] == "1" {
            MobileZoomStressView(engineProvider: terminalEngine)
        } else if ProcessInfo.processInfo.environment["CMUX_LATENCY_PROBE"] == "1" {
            MobileTerminalLatencyProbeView(engineProvider: terminalEngine)
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
        return CMUXMobileShellStore(
            runtime: runtime,
            pairedMacStore: pairedMacStore,
            identityProvider: identityProvider,
            reachability: reachability
        )
    }
}
