import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileTransport
import Foundation
import OSLog
import cmuxFeature
#if DEBUG
import CmuxIrohReleaseGateSupport
#endif

nonisolated private let cmuxAppConnectivityLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "connectivity"
)

/// Process-lifetime dependency graph used by the UIKit application and scene delegates.
@MainActor
enum CmuxApplication {
    static let root: AppCompositionRoot = {
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
        let connectivityInvalidationServiceURL = PresenceClient.resolvedServiceBaseURL(
            isDevelopmentAuthChannel: auth.authEnvironment == .development
        )
        let connectivityInvalidationBaseURL = connectivityInvalidationServiceURL
            .flatMap(URL.init(string:))
        if connectivityInvalidationBaseURL == nil {
            cmuxAppConnectivityLog.error(
                "Connectivity invalidation disabled: presence service URL unavailable"
            )
        }
        iroh.configure(
            auth: auth.coordinator,
            connectivityInvalidationBaseURL: connectivityInvalidationBaseURL
        )

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

    static func makeRootViewController() -> CMUXMobileRootViewController {
        let controller = CMUXMobileRootViewController(
            runtime: root.runtime,
            auth: root.auth,
            reachability: root.reachability,
            analytics: root.analytics.emitter,
            pushCoordinator: root.pushCoordinator,
            displaySettings: root.displaySettings,
            connectionMethodStore: root.connectionMethodStore,
            onboardingStore: root.onboardingStore,
            tailscaleStatusMonitor: root.tailscaleStatusMonitor,
            irohSettingsController: root.iroh,
            personalIrohRouteCatalog: root.iroh.routeCatalog,
            personalIrohDiscovery: root.iroh,
            personalIrohForget: root.iroh,
            signOutHook: root.signOutHook,
            diagnosticLog: root.diagnosticLog,
            prepareForDogfoodAttach: { [iroh = root.iroh] in
                await iroh.prepareForConnection()
            }
        )
        #if DEBUG
        return MobileIrohReleaseGateController.configure(root: controller, iroh: root.iroh)
        #else
        return controller
        #endif
    }
}
