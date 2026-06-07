import CMUXMobileCore
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
        #if targetEnvironment(simulator) || DEBUG
        let supportedKinds: [CmxAttachTransportKind] = [.debugLoopback, .tailscale]
        #else
        let supportedKinds: [CmxAttachTransportKind] = [.tailscale]
        #endif
        let networkFactory = CmxNetworkByteTransportFactory(supportedKinds: supportedKinds)
        let registrations = supportedKinds.map { kind in
            CmxRouteTransportFactoryRegistration(kind: kind, factory: networkFactory)
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
            CMUXMobileRootScene(
                runtime: Self.root.runtime,
                auth: Self.root.auth,
                reachability: Self.root.reachability,
                analytics: Self.root.analytics.emitter,
                pushCoordinator: Self.root.pushCoordinator
            )
            // `initial: true` so the cold-launch `.active` value (which `onChange`
            // otherwise skips) drives the first `ios_session_started` +
            // `ios_app_foregrounded`. Without it the whole session funnel stays
            // empty until the first background-and-return.
            .onChange(of: scenePhase, initial: true) { _, newPhase in
                Self.root.handleScenePhase(newPhase)
            }
        }
    }
}
