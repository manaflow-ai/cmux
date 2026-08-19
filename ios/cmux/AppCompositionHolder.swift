import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import Foundation
import Observation
import cmuxFeature

/// Owns the CURRENT ``AppCompositionRoot`` and replaces it during a live
/// backend-environment switch.
///
/// `cmuxApp` builds one holder at launch and keys the SwiftUI root scene on
/// ``generation``, so assigning a fresh root gives the whole tree a new
/// identity: every view, store, and environment value is rebuilt against the
/// new graph, which is what replaces the old "close and reopen cmux" step.
/// The switch itself runs through the shared
/// ``CmuxAuthRuntime/BackendEnvironmentSwitchTransaction`` so the ordering
/// invariant (sign out under the OLD defaults → quiesce → store override →
/// rebuild) has a single owner across both apps.
@MainActor
@Observable
final class AppCompositionHolder {
    /// The live composition root the scene tree renders from.
    private(set) var root: AppCompositionRoot

    /// Bumped on every rebuild; the root scene's `.id` boundary.
    private(set) var generation: UInt64 = 0

    /// The one apply path for a backend switch; drives the progress overlay.
    let switchTransaction = BackendEnvironmentSwitchTransaction()

    /// The UIKit app delegate whose push/analytics wiring must follow the
    /// current root. Weak: the delegate is owned by UIKit/`cmuxApp`. Not
    /// observable state — nothing renders from it.
    @ObservationIgnored private weak var appDelegate: CmuxAppDelegate?

    init(root: AppCompositionRoot) {
        self.root = root
    }

    /// Runs the launch-time delegate wiring against the CURRENT root, and
    /// remembers the delegate so a rebuilt root is re-wired the same way:
    /// the push coordinator becomes the notification-center delegate's
    /// backend, and the delegate's analytics emitter follows the new graph.
    func attach(appDelegate: CmuxAppDelegate) {
        self.appDelegate = appDelegate
        root.pushCoordinator.configure(delegate: appDelegate)
        appDelegate.pushCoordinator = root.pushCoordinator
        appDelegate.analytics = root.analytics.emitter
    }

    /// Performs one live switch to `target` through the shared transaction.
    /// Concurrent calls join the in-flight run; pinned builds and no-op
    /// targets are refused by the engine's guards.
    func performBackendSwitch(to target: CMUXBackendEnvironmentOverride) async {
        await switchTransaction.run(to: target, steps: makeSwitchSteps())
    }

    /// The platform steps for ``CmuxAuthRuntime/BackendEnvironmentSwitchTransaction``.
    ///
    /// Every closure resolves `self.root` at execution time: sign-out and
    /// quiesce run against the OLD root, and the rebuild closure replaces it,
    /// so a joined second caller can never act on a stale graph.
    private func makeSwitchSteps() -> BackendEnvironmentSwitchTransaction.Steps {
        BackendEnvironmentSwitchTransaction.Steps(
            isPinnedByBuild: { [weak self] in
                self?.root.auth.backendEnvironmentSwitch.isPinnedByBuild ?? true
            },
            activeEnvironment: { [weak self] in
                self?.root.auth.backendEnvironmentSwitch.active ?? .production
            },
            signOut: { [weak self] in
                guard let root = self?.root else { return }
                // The full sign-out flow CMUXMobileRootView.signOut composes,
                // minus the shell-store UI teardown: the tree swap at rebuild
                // replaces it wholesale. The hook fences iroh + push teardown
                // and receives auth's captured tokens so the bounded server
                // tail (push-token delete, binding revoke, Stack revocation)
                // hits the OLD backend before the override commit.
                root.diagnosticLog.recordAppEvent(.authSignOutStarted)
                let serverTeardown = root.signOutHook.begin()
                await root.auth.coordinator.signOut(onSignedOut: serverTeardown)
                let stillAuthenticated = root.auth.coordinator.isAuthenticated
                root.diagnosticLog.recordAppEvent(
                    stillAuthenticated ? .authSignOutFailed : .authSignOutSucceeded,
                    failure: stillAuthenticated ? .protocolViolation : nil
                )
            },
            quiesce: { [weak self] in
                await self?.root.shutdown()
            },
            storeOverride: { target in
                target.store(in: .standard)
            },
            rebuild: { [weak self] _ in
                guard let self else { return }
                let newRoot = AppCompositionRoot.assemble()
                self.root = newRoot
                if let appDelegate = self.appDelegate {
                    self.attach(appDelegate: appDelegate)
                }
                // Bump last: observers reading the new generation must see the
                // new root and its delegate wiring already in place.
                self.generation &+= 1
            }
        )
    }
}
