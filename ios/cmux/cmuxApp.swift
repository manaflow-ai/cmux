import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileTransport
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
        let buildCompatibilityPolicy = MobileMacBuildCompatibilityPolicy.current(
            buildScope: MobileIOSBuildScope.current(),
            compatibleMacTags: Bundle.main.object(
                forInfoDictionaryKey: "CMUXCompatibleMacTags"
            ) as? String
        )

        // `debugLoopback` (127.0.0.1) backs the UI-test mock Mac. Enable it on
        // the simulator and on DEBUG device builds so on-device XCUITests can
        // attach to an in-runner mock host; release device builds keep only
        // real transports.
        #if targetEnvironment(simulator) || DEBUG
        let supportedKinds: [CmxAttachTransportKind] = [.debugLoopback, .tcp]
        #else
        let supportedKinds: [CmxAttachTransportKind] = [.tcp]
        #endif

        let transportComposition = MobileTransportRuntimeComposition(
            apiBaseURL: auth.config.apiBaseURL,
            reachability: reachability,
            supportedKinds: supportedKinds,
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
        transportComposition.configure(
            auth: auth.coordinator,
            connectivityInvalidationBaseURL: connectivityInvalidationBaseURL
        )

        // Keep one factory at the composition boundary. Dispatching through a
        // kind-keyed registry would reject a persisted `.tailscale` label
        // before the stable factory can normalize it to `.tcp`.
        let runtime = CMUXMobileRuntime(
            transportFactory: transportComposition.transportFactory,
            stackAccessTokenProvider: CMUXMobileRuntime.stackAccessTokenProvider(from: auth.coordinator),
            stackAccessTokenForStatusProvider: CMUXMobileRuntime.stackAccessTokenForStatusProvider(from: auth.coordinator),
            stackAccessTokenForceRefresher: CMUXMobileRuntime.stackAccessTokenForceRefresher(from: auth.coordinator),
            supportsServerPushEvents: true
        )

        return AppCompositionRoot(
            runtime: runtime,
            auth: auth,
            transportComposition: transportComposition,
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
        Group { mobileRootScene }
        .environment(
            \.dogfoodAttachPreparation,
            DogfoodAttachPreparation {
                await Self.root.transportComposition.prepareForConnection()
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
            buildCompatibilityPolicy: Self.root.buildCompatibilityPolicy,
            signOutHook: Self.root.signOutHook,
            diagnosticLog: Self.root.diagnosticLog
        )
    }
}
