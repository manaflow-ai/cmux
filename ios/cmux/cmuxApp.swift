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
        let v2Configuration = MobileIrohV2Configuration.current(projectID: auth.config.stack.projectId)
        let irx = MobileIrxRuntimeComposition(configuration: v2Configuration,
            keychainAccessGroup: auth.keychainAccessGroup)
        Task { await irx.configure(auth: auth.coordinator) }
        let v3 = makeV3Runtime(auth: auth)
        if let v3 {
            Task { await v3.configure(auth: auth.coordinator) }
        }
        let v3Catalog = v3.map { _ in MobileIrohRouteCatalog() }
        let v3Discovery = v3.flatMap { runtime in
            v3Catalog.map { MobileV3DiscoveryProvider(runtime: runtime, preferredTag: "default", routeCatalog: $0) }
        }

        // `debugLoopback` (127.0.0.1) backs the UI-test mock Mac. Enable it on
        // the simulator and on DEBUG device builds so on-device XCUITests can
        // attach to an in-runner mock host; release device builds keep only
        // real transports. Force-relay mode (soak rigs) registers NO fallback
        // kinds so even a simulator exercises the real relay path.
        let forceRelay = irx.forceRelayOnly
        #if targetEnvironment(simulator) || DEBUG
        let supportedKinds: [CmxAttachTransportKind] =
            forceRelay ? [] : [.debugLoopback, .tailscale]
        #else
        let supportedKinds: [CmxAttachTransportKind] = forceRelay ? [] : [.tailscale]
        #endif
        let networkFactory = CmxNetworkByteTransportFactory(supportedKinds: supportedKinds)
        let fallbackRegistrations = supportedKinds.map { kind in
            CmxRouteTransportFactoryRegistration(kind: kind, factory: networkFactory)
        }
        var registrations = [
            CmxRouteTransportFactoryRegistration(
                kind: .iroh,
                factory: irx.transportFactory
            ),
        ]
        if let v3 {
            registrations.append(CmxRouteTransportFactoryRegistration(
                kind: .v3,
                factory: MobileV3DeferredTransportFactory(runtime: v3)
            ))
        }
        registrations += fallbackRegistrations
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
                if let v3, request.route.kind == .v3 { return try await v3.eventStream(for: request) }
                return try await irx.serverEventByteStream(for: request)
            },
            terminalLaneProvider: { request, surfaceID, cursor in
                if let v3, request.route.kind == .v3 { return try await v3.terminalLane(for: request, surfaceID: surfaceID, cursor: cursor) }
                guard let surfaceUUID = UUID(uuidString: surfaceID) else { throw MobileIrohTerminalLaneError.invalidSurfaceID }
                return try await irx.openTerminalLane(for: request, surfaceID: surfaceUUID, cursor: cursor)
            },
            terminalInputLaneProvider: { request, surfaceID, _ in
                if let v3, request.route.kind == .v3 { return try await v3.terminalInputLane(for: request, surfaceID: surfaceID) }
                guard let surfaceUUID = UUID(uuidString: surfaceID) else { throw MobileIrohTerminalLaneError.invalidSurfaceID }
                return try await irx.openTerminalInputLane(for: request, surfaceID: surfaceUUID)
            },
            artifactLaneProvider: { request, resourceID, offset in
                if let v3, request.route.kind == .v3 { return try await v3.artifactLane(for: request, resourceID: resourceID, offset: offset) }
                return try await irx.openArtifactLane(for: request, resourceID: resourceID, offset: offset)
            },
            simulatorStreamLaneProvider: { request, panelID in
                if let v3, request.route.kind == .v3 { return try await v3.simulatorLane(for: request, panelID: panelID) }
                guard let panelUUID = UUID(uuidString: panelID) else { throw MobileIrohSimulatorStreamLaneError.invalidPanelID }
                return try await irx.openSimulatorStreamLane(for: request, panelID: panelUUID)
            }
        )

        return AppCompositionRoot(
            runtime: runtime,
            auth: auth,
            irx: irx,
            v3: v3,
            v3Discovery: v3Discovery,
            v3RouteCatalog: v3Catalog,
            irxDiscovery: MobileIrxDiscoveryProvider(irx: irx, preferredTag: irx.tag,
                compatibilityPolicy: buildCompatibilityPolicy),
            buildCompatibilityPolicy: buildCompatibilityPolicy,
            reachability: reachability,
            diagnosticLog: diagnosticLog
        )
    }()

    @MainActor
    private static func makeV3Runtime(auth: MobileAuthComposition) -> MobileV3RuntimeComposition? {
        let environment = ProcessInfo.processInfo.environment
        guard let originString = environment["CMUX_V3_CONTROL_ORIGIN"],
              let origin = URL(string: originString),
              let rawKeys = environment["CMUX_V3_AUTHORITY_KEYS"],
              let data = rawKeys.data(using: .utf8),
              let encoded = try? JSONDecoder().decode([String: String].self, from: data),
              !encoded.isEmpty else { return nil }
        let keys = encoded.compactMapValues { value in Data(hexString: value) }
        guard keys.count == encoded.count else { return nil }
        guard let configuration = try? MobileV3RuntimeComposition.Configuration(
            controlOrigin: origin,
            audience: environment["CMUX_V3_AUDIENCE"] ?? "cmux-v3-\(auth.authEnvironment.rawValue)",
            authorityKeys: keys,
            keychainAccessGroup: auth.keychainAccessGroup
        ) else { return nil }
        return MobileV3RuntimeComposition(configuration: configuration)
    }

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
                irx: Self.root.irx,
                settingsController: Self.root.irohSettingsController
            )
            #else
            mobileRootScene
            #endif
        }
        .environment(\.irohSettingsController, Self.root.irohSettingsController)
        .environment(\.mobileKeyboardFrameTracker, Self.root.keyboardFrameTracker)
        .environment(
            \.dogfoodAttachPreparation,
            DogfoodAttachPreparation {
                await Self.root.irx.didBecomeActive()
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
            // First-pair discovery must come from the ACTIVE transport: the
            // dormant one answers "endpoint unavailable" and a fresh install
            // (empty paired-Mac store) then lists zero Macs forever.
            personalIrohRouteCatalog: Self.root.v3RouteCatalog ?? Self.root.irxDiscovery.routeCatalog,
            personalIrohDiscovery: Self.root.v3Discovery ?? Self.root.irxDiscovery,
            personalIrohForget: Self.root.v3Discovery == nil ? Self.root.irxDiscovery : nil,
            buildCompatibilityPolicy: Self.root.buildCompatibilityPolicy,
            signOutHook: Self.root.signOutHook,
            diagnosticLog: Self.root.diagnosticLog,
            appLog: Self.root.appLog,
            v2Configuration: Self.root.irx.configuration
        )
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2), !hexString.isEmpty else { return nil }
        var value = Data(capacity: hexString.count / 2)
        for index in stride(from: 0, to: hexString.count, by: 2) {
            let start = hexString.index(hexString.startIndex, offsetBy: index)
            let end = hexString.index(start, offsetBy: 2)
            guard let byte = UInt8(hexString[start..<end], radix: 16) else { return nil }
            value.append(byte)
        }
        self = value
    }
}
