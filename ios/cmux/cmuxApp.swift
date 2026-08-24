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
/// swaps the whole tree via `.id` while the overlay rides above the swap.
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
            // tree swap: it blocks while the graph is torn down/rebuilt and
            // becomes a non-blocking banner/note once the rebuilt tree must
            // be interactive (establishing sign-in, finished outcome).
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
    ///
    /// The picker option maps to the host SELECTION here (the app-root
    /// equivalent of macOS `HostAccountFlow.hostSelection(from:)`):
    /// `.buildLane` is the lane, and on a PRODUCTION lane the picker's
    /// "Production" option also maps to the lane (clearChoice — the key stays
    /// absent, preserving the two-position picker's pre-tri-state semantics),
    /// while on any other lane "Production" is the explicit wholesale choice.
    private var backendEnvironmentSwitchAction: BackendEnvironmentSwitchAction {
        let phase: BackendEnvironmentSwitchAction.Phase
        switch composition.switchTransaction.phase {
        case .idle: phase = .idle
        case .parking: phase = .parking
        case .retargeting: phase = .retargeting
        case .establishing: phase = .establishing
        case .reverting: phase = .reverting
        case .finished: phase = .finished
        }
        let composition = composition
        return BackendEnvironmentSwitchAction(phase: phase) { target in
            // The lane is read at begin time from the CURRENT root, so a
            // second switch after a rebuild maps against live state.
            let lane = composition.root.auth.backendEnvironmentSwitch.buildLane
            let hostTarget: CMUXBackendEnvironmentSelection
            switch target {
            case .buildLane:
                hostTarget = .lane(resolves: lane.resolvedEnvironment)
            case .production:
                hostTarget = lane == .production
                    ? .lane(resolves: .production)
                    : .explicit(.production)
            case .staging:
                hostTarget = .explicit(.staging)
            }
            Task { await composition.performBackendSwitch(to: hostTarget) }
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

/// Progress layer for the live backend switch.
///
/// Mounted ABOVE the root scene's `.id` boundary, so it stays up while the
/// old tree is discarded and the new one mounts. Three tiers:
///
/// - `.parking` / `.retargeting` / `.reverting`: a full-screen blocking scrim
///   with a spinner and the localized phase — the tree underneath is being
///   torn down or rebuilt, so nothing may interact with it.
/// - `.establishing` on a gated target (staging): a NON-BLOCKING top banner
///   ("Sign in to Staging to finish switching" with a "Back to Production"
///   revert affordance). The rebuilt tree underneath already shows
///   `SignInView`, and the user must be able to use it — the banner is the
///   only overlay, everything around it passes touches through. Ungated
///   establishing (a production switch restoring its parked slot) shows
///   nothing: production never prompts, so there is no wait to explain.
/// - `.finished(outcome)`: a non-blocking outcome note ("Now on X", or the
///   localized revert reason) that never intercepts touches and auto-clears
///   through the overlay's `.task(id:)` clock, then resets the transaction.
private struct BackendEnvironmentSwitchOverlay: View {
    let composition: AppCompositionHolder

    /// Bounded auto-dismiss for the finished note. Runs on the overlay's
    /// `.task`, so leaving the finished phase (or unmounting) cancels it.
    private static let dismissClock = ContinuousClock()
    private static let switchedNoteDuration: Duration = .seconds(2)
    /// Revert notes carry a reason sentence; give them time to be read.
    private static let revertedNoteDuration: Duration = .seconds(4)

    var body: some View {
        let transaction = composition.switchTransaction
        Group {
            switch transaction.phase {
            case .idle:
                EmptyView()
            case .parking, .retargeting, .reverting:
                blockingProgress(phase: transaction.phase)
            case .establishing:
                // Only a gated target waits on a sign-in; an ungated target's
                // establishing is just its parked-slot restore and needs no
                // overlay (and must not offer a revert of a switch TO it).
                // After the rebuild the CURRENT root's selection IS the
                // target, and only explicit staging gates — a staging LANE
                // never does.
                if composition.root.auth.backendEnvironmentSwitch.selection.requiresGatedSession {
                    establishingBanner(transaction: transaction)
                }
            case .finished(let outcome):
                finishedNote(outcome: outcome)
                    .task(id: transaction.phase) {
                        let duration: Duration = switch outcome {
                        case .switched: Self.switchedNoteDuration
                        case .reverted: Self.revertedNoteDuration
                        }
                        try? await Self.dismissClock.sleep(for: duration)
                        guard !Task.isCancelled else { return }
                        transaction.reset()
                    }
            }
        }
    }

    // MARK: - Blocking progress (parking / retargeting / reverting)

    private func blockingProgress(
        phase: BackendEnvironmentSwitchTransaction.Phase
    ) -> some View {
        ZStack {
            Color.black
                .opacity(0.5)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(phaseText(phase))
                    .font(.headline)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("BackendEnvironmentSwitchOverlay")
        }
        .transition(.opacity)
    }

    private func phaseText(_ phase: BackendEnvironmentSwitchTransaction.Phase) -> String {
        switch phase {
        case .parking:
            L10n.string(
                "mobile.settings.backend.progressParking",
                defaultValue: "Saving your session…"
            )
        case .reverting:
            L10n.string(
                "mobile.settings.backend.progressReverting",
                defaultValue: "Switching back…"
            )
        case .retargeting, .idle, .establishing, .finished:
            L10n.string(
                "mobile.settings.backend.progressSwitching",
                defaultValue: "Switching environment…"
            )
        }
    }

    // MARK: - Establishing banner (non-blocking)

    /// The sign-in wait banner: pinned to the top, hit-testable only inside
    /// its own card so the `SignInView` underneath stays fully interactive.
    private func establishingBanner(
        transaction: BackendEnvironmentSwitchTransaction
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                String(
                    format: L10n.string(
                        "mobile.settings.backend.establishingBanner",
                        defaultValue: "Sign in to %@ to finish switching"
                    ),
                    activeEnvironmentName
                )
            )
            .font(.subheadline.weight(.semibold))
            Button {
                transaction.requestRevert()
            } label: {
                Text(L10n.string(
                    "mobile.settings.backend.establishingRevert",
                    defaultValue: "Back to Production"
                ))
                .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("BackendEnvironmentSwitchRevertButton")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(.opacity)
        .accessibilityIdentifier("BackendEnvironmentSwitchEstablishingBanner")
    }

    // MARK: - Finished note (non-blocking)

    private func finishedNote(
        outcome: BackendEnvironmentSwitchTransaction.Outcome
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: outcome == .switched
                ? "checkmark.circle.fill"
                : "arrow.uturn.backward.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(outcome == .switched ? Color.green : Color.orange)
            Text(outcomeText(outcome))
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
        .accessibilityIdentifier("BackendEnvironmentSwitchFinishedNote")
        // Purely informational: the freshly mounted tree (sign-in on
        // staging, the restored shell after a revert) must be immediately
        // usable, so the note never intercepts a touch.
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// The outcome copy, formatted with the environment the REBUILT root
    /// resolved: after a switch that is the user's choice, after a revert it
    /// is the previous environment the run restored. A switch that landed on
    /// the LANE selection names the lane (its bake), not just the resolved
    /// environment.
    private func outcomeText(
        _ outcome: BackendEnvironmentSwitchTransaction.Outcome
    ) -> String {
        let name = activeEnvironmentName
        switch outcome {
        case .switched:
            if case .lane = composition.root.auth.backendEnvironmentSwitch.selection {
                return String(
                    format: L10n.string(
                        "mobile.settings.backend.switchedLane",
                        defaultValue: "Now on the build lane (%@)."
                    ),
                    buildLaneLabel
                )
            }
            return String(
                format: L10n.string(
                    "mobile.settings.backend.switched",
                    defaultValue: "Now on %@."
                ),
                name
            )
        case .reverted(.signInCancelled):
            return String(
                format: L10n.string(
                    "mobile.settings.backend.revertedSignInCancelled",
                    defaultValue: "Sign-in was cancelled, so you're back on %@."
                ),
                name
            )
        case .reverted(.signInFailed):
            return String(
                format: L10n.string(
                    "mobile.settings.backend.revertedSignInFailed",
                    defaultValue: "Sign-in didn't complete, so you're back on %@."
                ),
                name
            )
        case .reverted(.notEligible):
            return String(
                format: L10n.string(
                    "mobile.settings.backend.revertedNotEligible",
                    defaultValue: "That account can't use Staging, so you're back on %@."
                ),
                name
            )
        }
    }

    private var activeEnvironmentName: String {
        switch composition.root.auth.backendEnvironmentSwitch.selection.resolvedEnvironment {
        case .production:
            L10n.string("mobile.settings.backend.production", defaultValue: "Production")
        case .staging:
            L10n.string("mobile.settings.backend.staging", defaultValue: "Staging")
        }
    }

    /// The human name substituted into "Now on the build lane (%@)." — the
    /// lane's environment name, or a custom lane's baked host[:port] label.
    private var buildLaneLabel: String {
        switch composition.root.auth.backendEnvironmentSwitch.buildLane {
        case .production:
            L10n.string("mobile.settings.backend.production", defaultValue: "Production")
        case .staging:
            L10n.string("mobile.settings.backend.staging", defaultValue: "Staging")
        case .custom(let label):
            label
        }
    }
}
