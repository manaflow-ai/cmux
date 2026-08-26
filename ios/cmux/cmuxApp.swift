import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileTransport
import Foundation
import OSLog
import SwiftUI
import cmuxFeature
#if DEBUG
import CmuxIrohReleaseGateSupport
#endif

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
        let iroh = MobileIrohRuntimeComposition(
            apiBaseURL: auth.config.apiBaseURL,
            reachability: reachability,
            discoveryCompatibilityPolicy: buildCompatibilityPolicy,
            appNamespace: auth.appNamespace,
            keychainAccessGroup: auth.keychainAccessGroup,
            diagnosticLog: diagnosticLog
        )
        let connectivityInvalidationServiceURL = PresenceClient
            .resolvedServiceBaseURL(
                isDevelopmentAuthChannel: auth.authEnvironment == .development
            )
        let connectivityInvalidationBaseURL = connectivityInvalidationServiceURL
            .flatMap { URL(string: $0) }
        if connectivityInvalidationBaseURL == nil {
            cmuxAppConnectivityLog.error(
                "Connectivity invalidation disabled: presence service URL unavailable"
            )
        }
        // Exactly one iroh runtime owns the app's broker binding slot: the
        // irx rebuild when its DEBUG flag is on, the legacy composition
        // otherwise. The unconfigured one stays dormant.
        let irxEnabled = MobileIrxRuntimeComposition.isEnabled
        let irx = MobileIrxRuntimeComposition(
            apiBaseURL: auth.config.apiBaseURL,
            appNamespace: auth.appNamespace,
            keychainAccessGroup: auth.keychainAccessGroup
        )
        if irxEnabled {
            let coordinator = auth.coordinator
            Task { await irx.configure(auth: coordinator) }
        } else {
            iroh.configure(
                auth: auth.coordinator,
                connectivityInvalidationBaseURL: connectivityInvalidationBaseURL
            )
        }

        // `debugLoopback` (127.0.0.1) backs the UI-test mock Mac. Enable it on
        // the simulator and on DEBUG device builds so on-device XCUITests can
        // attach to an in-runner mock host; release device builds keep only
        // real transports. In irx mode NO fallback kinds register, so even a
        // simulator exercises the real iroh path instead of loopback.
        #if targetEnvironment(simulator) || DEBUG
        let supportedKinds: [CmxAttachTransportKind] =
            irxEnabled ? [] : [.debugLoopback, .tailscale]
        #else
        let supportedKinds: [CmxAttachTransportKind] = irxEnabled ? [] : [.tailscale]
        #endif
        let networkFactory = CmxNetworkByteTransportFactory(supportedKinds: supportedKinds)
        let fallbackRegistrations = supportedKinds.map { kind in
            CmxRouteTransportFactoryRegistration(kind: kind, factory: networkFactory)
        }
        let registrations = [
            CmxRouteTransportFactoryRegistration(
                kind: .iroh,
                factory: irxEnabled ? irx.transportFactory : iroh.transportFactory
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
                irxEnabled
                    ? try await irx.serverEventByteStream(for: request)
                    : try await iroh.serverEventByteStream(for: request)
            },
            terminalLaneProvider: { request, surfaceID, cursor in
                guard let surfaceUUID = UUID(uuidString: surfaceID) else {
                    throw MobileIrohTerminalLaneError.invalidSurfaceID
                }
                return irxEnabled
                    ? try await irx.openTerminalLane(
                        for: request,
                        surfaceID: surfaceUUID,
                        cursor: cursor
                    )
                    : try await iroh.openTerminalLane(
                        for: request,
                        surfaceID: surfaceUUID,
                        cursor: cursor
                    )
            },
            artifactLaneProvider: { request, resourceID, offset in
                irxEnabled
                    ? try await irx.openArtifactLane(
                        for: request,
                        resourceID: resourceID,
                        offset: offset
                    )
                    : try await iroh.openArtifactLane(
                        for: request,
                        resourceID: resourceID,
                        offset: offset
                    )
            },
            simulatorStreamLaneProvider: { request, panelID in
                guard let panelUUID = UUID(uuidString: panelID) else {
                    throw MobileIrohSimulatorStreamLaneError.invalidPanelID
                }
                guard !irxEnabled else {
                    // Simulator streaming is not served by irx v1.
                    throw MobileIrohSimulatorStreamLaneError.closed
                }
                return try await iroh.openSimulatorStreamLane(
                    for: request,
                    panelID: panelUUID
                )
            }
        )

        return AppCompositionRoot(
            runtime: runtime,
            auth: auth,
            iroh: iroh,
            irx: irxEnabled ? irx : nil,
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
        .environment(\.mobileKeyboardFrameTracker, Self.root.keyboardFrameTracker)
        .environment(
            \.dogfoodAttachPreparation,
            DogfoodAttachPreparation {
                if let irx = Self.root.irx {
                    await irx.didBecomeActive()
                } else {
                    await Self.root.iroh.prepareForConnection()
                }
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
            featureFlags: Self.root.featureFlags,
            connectionMethodStore: Self.root.connectionMethodStore,
            autoConnectMigrationStore: Self.root.autoConnectMigrationStore,
            onboardingStore: Self.root.onboardingStore,
            tailscaleStatusMonitor: Self.root.tailscaleStatusMonitor,
            personalIrohRouteCatalog: Self.root.iroh.routeCatalog,
            personalIrohDiscovery: Self.root.iroh,
            personalIrohForget: Self.root.iroh,
            buildCompatibilityPolicy: Self.root.buildCompatibilityPolicy,
            signOutHook: Self.root.signOutHook,
            diagnosticLog: Self.root.diagnosticLog
        )
    }
}
