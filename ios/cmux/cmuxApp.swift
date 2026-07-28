import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileTransport
import Foundation
import SwiftUI
import cmuxFeature
#if DEBUG
import CmuxIrohReleaseGateSupport
#endif

@main
struct cmuxApp: App {
    @UIApplicationDelegateAdaptor(CmuxAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    /// The de-singletonized composition root: built once, injected down.
    @MainActor
    private static let root: AppCompositionRoot = {
        let reachability = ReachabilityService()
        let auth = MobileAuthComposition(reachability: reachability)
        auth.start()
        let diagnosticLog = DiagnosticLog(
            buildStamp: AppCompositionRoot.diagnosticBuildStamp,
            role: .iosClient
        )
        let buildCompatibilityPolicy = MobileMacBuildCompatibilityPolicy.current(
            buildScope: MobileIOSBuildScope.current()
        )
        let iroh = MobileIrohRuntimeComposition(
            apiBaseURL: auth.config.apiBaseURL,
            reachability: reachability,
            discoveryCompatibilityPolicy: buildCompatibilityPolicy,
            diagnosticLog: diagnosticLog
        )
        iroh.configure(auth: auth.coordinator)

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
        Group {
            #if DEBUG
            MobileIrohReleaseGateScene(
                root: mobileRootScene,
                iroh: Self.root.iroh
            )
            #else
            mobileRootScene
            #endif
        }
        .environment(\.irohSettingsController, Self.root.iroh)
        .environment(
            \.dogfoodAttachPreparation,
            DogfoodAttachPreparation {
                await Self.root.iroh.prepareForConnection()
            }
        )
    }

    private var mobileRootScene: CMUXMobileRootScene {
        CMUXMobileRootScene(
            runtime: Self.root.runtime,
            auth: Self.root.auth,
            reachability: Self.root.reachability,
            analytics: Self.root.analytics.emitter,
            pushCoordinator: Self.root.pushCoordinator,
            displaySettings: Self.root.displaySettings,
            onboardingStore: Self.root.onboardingStore,
            tailscaleStatusMonitor: Self.root.tailscaleStatusMonitor,
            personalIrohRouteCatalog: Self.root.iroh.routeCatalog,
            personalIrohDiscovery: Self.root.iroh,
            signOutHook: Self.root.signOutHook,
            diagnosticLog: Self.root.diagnosticLog
        )
    }
}
