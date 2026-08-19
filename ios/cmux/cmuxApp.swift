import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileSupport
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

    /// The replaceable composition: the de-singletonized graph is built once
    /// at launch (`AppCompositionRoot.assemble()`) and rebuilt in place by the
    /// live backend-environment switch. Views key off `generation`, so a
    /// rebuild swaps the whole tree's identity instead of relaunching.
    @MainActor
    private static let composition = AppCompositionHolder(
        root: AppCompositionRoot.assemble()
    )

    init() {
        Self.composition.attach(appDelegate: appDelegate)
    }

    var body: some Scene {
        WindowGroup {
            AppCompositionRootHost(composition: Self.composition)
                // `initial: true` so the cold-launch `.active` value (which
                // `onChange` otherwise skips) drives the first
                // `ios_session_started` + `ios_app_foregrounded`. Without it
                // the whole session funnel stays empty until the first
                // background-and-return. Resolved through the holder per
                // event so a rebuilt root receives the scene phases too.
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    Self.composition.root.handleScenePhase(newPhase)
                }
        }
    }
}

/// Hosts the current composition root's scene tree behind the generation
/// identity boundary, with the backend-switch progress overlay above it.
///
/// A dedicated `View` (not the `App`/`WindowGroup` closure) so the reads of
/// `composition.root`, `composition.generation`, and the transaction phase are
/// Observation-tracked: assigning a rebuilt root re-renders this body, which
/// swaps the whole tree via `.id` while the overlay keeps covering the screen.
private struct AppCompositionRootHost: View {
    let composition: AppCompositionHolder

    var body: some View {
        ZStack {
            rootScene
                // The identity boundary for the live backend switch: a new
                // generation discards the whole tree (stores, sheets,
                // navigation) and rebuilds it over the new root.
                .id(composition.generation)
            // ABOVE the .id boundary so the progress overlay survives the
            // tree swap and keeps covering the screen until `.finished`.
            BackendEnvironmentSwitchOverlay(composition: composition)
        }
        .environment(
            \.backendEnvironmentSwitchAction,
            backendEnvironmentSwitchAction
        )
    }

    /// Mirrors the transaction phase into the Settings-facing action value;
    /// reading `switchTransaction.phase` here re-injects a fresh action on
    /// every phase change so the picker disables while a switch runs.
    private var backendEnvironmentSwitchAction: BackendEnvironmentSwitchAction {
        let phase: BackendEnvironmentSwitchAction.Phase
        switch composition.switchTransaction.phase {
        case .idle: phase = .idle
        case .signingOut: phase = .signingOut
        case .retargeting: phase = .retargeting
        case .finished: phase = .finished
        }
        let composition = composition
        return BackendEnvironmentSwitchAction(phase: phase) { target in
            Task { await composition.performBackendSwitch(to: target) }
        }
    }

    @ViewBuilder
    private var rootScene: some View {
        let root = composition.root
        Group {
            #if DEBUG
            MobileIrohReleaseGateScene(
                root: mobileRootScene,
                iroh: root.iroh
            )
            #else
            mobileRootScene
            #endif
        }
        .environment(\.irohSettingsController, root.iroh)
        .environment(
            \.dogfoodAttachPreparation,
            DogfoodAttachPreparation { [weak root] in
                await root?.iroh.prepareForConnection()
            }
        )
    }

    private var mobileRootScene: CMUXMobileRootScene {
        let root = composition.root
        return CMUXMobileRootScene(
            runtime: root.runtime,
            auth: root.auth,
            reachability: root.reachability,
            analytics: root.analytics.emitter,
            pushCoordinator: root.pushCoordinator,
            displaySettings: root.displaySettings,
            featureFlags: root.featureFlags,
            connectionMethodStore: root.connectionMethodStore,
            autoConnectMigrationStore: root.autoConnectMigrationStore,
            onboardingStore: root.onboardingStore,
            tailscaleStatusMonitor: root.tailscaleStatusMonitor,
            personalIrohRouteCatalog: root.iroh.routeCatalog,
            personalIrohDiscovery: root.iroh,
            personalIrohForget: root.iroh,
            buildCompatibilityPolicy: root.buildCompatibilityPolicy,
            signOutHook: root.signOutHook,
            diagnosticLog: root.diagnosticLog
        )
    }
}

/// Full-screen progress cover for the live backend switch.
///
/// Mounted ABOVE the root scene's `.id` boundary, so it stays up while the
/// old tree is discarded and the new one mounts. Shows a dimmed background,
/// a spinner with the current phase, and a brief "Switched to X" note once
/// the transaction finishes, then resets the transaction back to idle.
private struct BackendEnvironmentSwitchOverlay: View {
    let composition: AppCompositionHolder

    /// Bounded auto-dismiss for the switched note. Runs on the overlay's
    /// `.task`, so leaving the finished phase (or unmounting) cancels it.
    private static let dismissClock = ContinuousClock()
    private static let switchedNoteDuration: Duration = .seconds(2)

    var body: some View {
        let transaction = composition.switchTransaction
        if transaction.phase != .idle {
            ZStack {
                Color.black
                    .opacity(0.5)
                    .ignoresSafeArea()
                VStack(spacing: 14) {
                    if transaction.phase == .finished {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.green)
                        Text(switchedText)
                            .font(.headline)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                        Text(phaseText(transaction.phase))
                            .font(.headline)
                    }
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("BackendEnvironmentSwitchOverlay")
            }
            .transition(.opacity)
            .task(id: transaction.phase) {
                guard transaction.phase == .finished else { return }
                try? await Self.dismissClock.sleep(for: Self.switchedNoteDuration)
                guard !Task.isCancelled else { return }
                transaction.reset()
            }
        }
    }

    private func phaseText(_ phase: BackendEnvironmentSwitchTransaction.Phase) -> String {
        switch phase {
        case .signingOut:
            L10n.string(
                "mobile.settings.backend.progressSigningOut",
                defaultValue: "Signing out…"
            )
        case .retargeting, .idle, .finished:
            L10n.string(
                "mobile.settings.backend.progressSwitching",
                defaultValue: "Switching environment…"
            )
        }
    }

    /// "Switched to X", where X is the environment the REBUILT root resolved;
    /// after the commit + rebuild this is exactly the user's choice.
    private var switchedText: String {
        let active = composition.root.auth.backendEnvironmentSwitch.active
        let name = switch active {
        case .production:
            L10n.string("mobile.settings.backend.production", defaultValue: "Production")
        case .staging:
            L10n.string("mobile.settings.backend.staging", defaultValue: "Staging")
        }
        return String(
            format: L10n.string(
                "mobile.settings.backend.switched",
                defaultValue: "Switched to %@"
            ),
            name
        )
    }
}
