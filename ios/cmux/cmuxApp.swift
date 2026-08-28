import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileTransport
import CmuxRelayTransport
import Foundation
import OSLog
import SwiftUI
import cmuxFeature

nonisolated private let cmuxAppConnectivityLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "connectivity"
)

@main
struct cmuxApp: App {
    @UIApplicationDelegateAdaptor(CmuxAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    /// The de-singletonized composition root: built once, injected down.
    @MainActor
    private static let root: AppCompositionRoot = {
        let reachability = ReachabilityService()
        let diagnosticLog = DiagnosticLog(
            buildStamp: AppCompositionRoot.diagnosticBuildStamp,
            role: .iosClient
        )
        let auth = MobileAuthComposition(
            reachability: reachability,
            diagnosticLog: diagnosticLog
        )
        // Per-tag isolation by default: this build pairs only with its own
        // Mac tag plus the runtime grant set its anchor Mac advertises
        // (`cmux mobile compatible-tags`), persisted across launches.
        let buildCompatibilityPolicy = MobileMacBuildCompatibilityPolicy.current(
            buildScope: MobileIOSBuildScope.current(),
            additionalInstanceTags: MobileMacTagAllowlist.persisted()
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
        // cmux Connect (`.websocket` routes through the HostRelay Durable
        // Object) is the built-in any-network transport. The dial
        // authenticates with the account's own Stack access token (verified
        // by the relay worker) and the transport's first frame admits the
        // session end to end on the Mac; there is no ticket and no web-API
        // call.
        let relayCoordinator = auth.coordinator
        let relayFactory = RelayClientTransportFactory(
            deviceID: { await DeviceRegistryService.deviceID() },
            accessToken: { try await relayCoordinator.accessToken() }
        )
        let registrations = [
            CmxRouteTransportFactoryRegistration(kind: .websocket, factory: relayFactory),
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
            stackAccessTokenForceRefresher: CMUXMobileRuntime.stackAccessTokenForceRefresher(from: auth.coordinator)
        )

        return AppCompositionRoot(
            runtime: runtime,
            auth: auth,
            buildCompatibilityPolicy: buildCompatibilityPolicy,
            reachability: reachability,
            diagnosticLog: diagnosticLog
        )
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
        mobileRootScene
            .environment(\.mobileKeyboardFrameTracker, Self.root.keyboardFrameTracker)
    }

    private var mobileRootScene: CMUXMobileRootScene {
        CMUXMobileRootScene(
            runtime: Self.root.runtime,
            auth: Self.root.auth,
            reachability: Self.root.reachability,
            analytics: Self.root.analytics.emitter,
            pushCoordinator: Self.root.pushCoordinator,
            displaySettings: Self.root.displaySettings,
            featureFlags: Self.root.featureFlags,
            connectionMethodStore: Self.root.connectionMethodStore,
            autoConnectMigrationStore: Self.root.autoConnectMigrationStore,
            onboardingStore: Self.root.onboardingStore,
            tailscaleStatusMonitor: Self.root.tailscaleStatusMonitor,
            buildCompatibilityPolicy: Self.root.buildCompatibilityPolicy,
            signOutHook: Self.root.signOutHook,
            diagnosticLog: Self.root.diagnosticLog
        )
    }
}
