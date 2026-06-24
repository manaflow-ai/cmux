import CMUXMobileCore
import CmuxMobileIrohTransport
import CmuxMobileTransport
import SwiftUI
import cmuxFeature

@main
struct cmuxApp: App {
    @UIApplicationDelegateAdaptor(CmuxAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    /// The de-singletonized composition root: built once, injected down.
    @MainActor
    private static let root: AppCompositionRoot = {
        // `debugLoopback` (127.0.0.1) backs the UI-test mock Mac. Enable it on
        // the simulator and on DEBUG device builds so on-device XCUITests can
        // attach to an in-runner mock host; release device builds keep only
        // real transports.
        // `debugLoopback` (127.0.0.1) is the Network.framework lane; iroh is the
        // dial-by-EndpointId lane (plans/feat-ios-iroh/DESIGN.md). iroh is
        // registered on simulator + DEBUG only for now; it stays inert until a
        // Mac publishes an iroh route (PR 4), at which point `preferredRoute`
        // picks it over tailscale on these builds.
        #if targetEnvironment(simulator) || DEBUG
        let networkKinds: [CmxAttachTransportKind] = [.debugLoopback, .tailscale]
        let irohEnabled = true
        #else
        let networkKinds: [CmxAttachTransportKind] = [.tailscale]
        let irohEnabled = false
        #endif
        let networkFactory = CmxNetworkByteTransportFactory(supportedKinds: networkKinds)
        var registrations = networkKinds.map { kind in
            CmxRouteTransportFactoryRegistration(kind: kind, factory: networkFactory)
        }
        if irohEnabled {
            registrations.append(
                CmxRouteTransportFactoryRegistration(kind: .iroh, factory: CmxIrohByteTransportFactory())
            )
        }
        let transportFactory: CmxRouteTransportFactory
        do {
            transportFactory = try CmxRouteTransportFactory(registrations)
        } catch {
            preconditionFailure("Invalid mobile transport registrations: \(error)")
        }

        let reachability = ReachabilityService()
        let auth = MobileAuthComposition(reachability: reachability)
        auth.start()

        let runtime = CMUXMobileRuntime(
            transportFactory: transportFactory,
            stackAccessTokenProvider: CMUXMobileRuntime.stackAccessTokenProvider(from: auth.coordinator),
            stackAccessTokenForStatusProvider: CMUXMobileRuntime.stackAccessTokenForStatusProvider(from: auth.coordinator),
            stackAccessTokenForceRefresher: CMUXMobileRuntime.stackAccessTokenForceRefresher(from: auth.coordinator)
        )

        return AppCompositionRoot(runtime: runtime, auth: auth, reachability: reachability)
    }()

    init() {
        Self.root.pushCoordinator.configure(delegate: appDelegate)
        appDelegate.pushCoordinator = Self.root.pushCoordinator
        appDelegate.analytics = Self.root.analytics.emitter
    }

    var body: some Scene {
        WindowGroup {
            rootScene
                // `initial: true` so the cold-launch `.active` value (which
                // `onChange` otherwise skips) drives the first
                // `ios_session_started` + `ios_app_foregrounded`. Without it the
                // whole session funnel stays empty until the first
                // background-and-return.
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    Self.root.handleScenePhase(newPhase)
                }
        }
    }

    @ViewBuilder
    private var rootScene: some View {
        #if DEBUG
        CMUXMobileRootScene(
            runtime: Self.root.runtime,
            auth: Self.root.auth,
            reachability: Self.root.reachability,
            analytics: Self.root.analytics.emitter,
            pushCoordinator: Self.root.pushCoordinator,
            displaySettings: Self.root.displaySettings,
            onboardingStore: Self.root.onboardingStore,
            tailscaleStatusMonitor: Self.root.tailscaleStatusMonitor,
            diagnosticLog: Self.root.diagnosticLog
        )
        #else
        CMUXMobileRootScene(
            runtime: Self.root.runtime,
            auth: Self.root.auth,
            reachability: Self.root.reachability,
            analytics: Self.root.analytics.emitter,
            pushCoordinator: Self.root.pushCoordinator,
            displaySettings: Self.root.displaySettings,
            onboardingStore: Self.root.onboardingStore,
            tailscaleStatusMonitor: Self.root.tailscaleStatusMonitor
        )
        #endif
    }
}
