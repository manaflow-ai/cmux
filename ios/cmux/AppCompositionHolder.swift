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
/// invariant (PARK the session under the OLD defaults → quiesce → store the
/// selection → rebuild → establish a session on the target) has a single
/// owner across both apps. Targets are SELECTIONS: an explicit choice
/// persists its raw value, a lane target clears the key, and the no-op guard
/// compares selection identity.
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

    /// The in-flight `promptSignIn` wait over the rebuilt coordinator's
    /// identity stream. Held so the transaction's `cancelSignInPrompt` step
    /// (`requestRevert()`) can cancel it: cancelling the task terminates the
    /// stream iteration inside `waitForNextSignedInUser()`, which then
    /// resolves `nil` — the prompt's cancel outcome. Not observable state.
    @ObservationIgnored private var signInPromptWait: Task<CMUXAuthUser?, Never>?

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

    /// Performs one live switch to the `target` SELECTION through the shared
    /// transaction. Concurrent calls join the in-flight run; a no-op target
    /// (same selection identity — so a staging-LANE build may still pick
    /// explicit staging) is refused by the engine's guard.
    func performBackendSwitch(to target: CMUXBackendEnvironmentSelection) async {
        await switchTransaction.run(to: target, steps: makeSwitchSteps())
    }

    /// The platform steps for ``CmuxAuthRuntime/BackendEnvironmentSwitchTransaction``.
    ///
    /// Every closure resolves `self.root` at execution time: park and quiesce
    /// run against the OLD root, the rebuild closure replaces it, and the
    /// establishing steps (`awaitRestoredUser`/`promptSignIn`/
    /// `signOutEstablishedSession`) then act on the NEW root — so a joined
    /// second caller can never act on a stale graph.
    private func makeSwitchSteps() -> BackendEnvironmentSwitchTransaction.Steps {
        BackendEnvironmentSwitchTransaction.Steps(
            activeSelection: { [weak self] in
                self?.root.auth.backendEnvironmentSwitch.selection
                    ?? .lane(resolves: .production)
            },
            parkSession: { [weak self] in
                guard let root = self?.root else { return }
                // Park, don't sign out: detach the published session while
                // the old environment's token slot survives for the return
                // switch. Deliberately NOT `signOutHook.begin()` — that hook
                // fences iroh (`beginSignOutPreparation` wipes binding state
                // and durably queues a revocation, killing the parked
                // environment's pairing) and queues the push-token DELETE,
                // both of which must not run for a parked session. The
                // quiesce step's `root.shutdown()` already stops iroh
                // non-destructively. No structured sign-out diagnostics
                // either: parking is not a sign-out, and recording
                // authSignOut* here would corrupt that funnel — the
                // coordinator's own auth debug log records the detach.
                await root.auth.coordinator.detachSessionLeavingTokens()
            },
            quiesce: { [weak self] in
                await self?.root.shutdown()
            },
            storeSelection: { target in
                // The commit point: an explicit choice persists its raw value
                // (production included — tri-state), a lane target clears the
                // key so the build's own bake resolves again.
                switch target {
                case .explicit(let choice):
                    choice.storeChoice(in: .standard)
                case .lane:
                    CMUXBackendEnvironmentOverride.clearChoice(in: .standard)
                }
                // EVERY committed selection (including a revert's, and lane
                // clears — a lane↔explicit flip can change the Stack project
                // too) arms the one-shot suppression so the immediate rebuild
                // — or the next launch after a crash — restores the target's
                // PARKED slot instead of running the organic project-flip
                // clear.
                CMUXBackendEnvironmentSwitchRebuildMarker.arm(in: .standard)
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
            },
            awaitRestoredUser: { [weak self] in
                // Resolve `self.root` at call time: after the rebuild step
                // this awaits the NEW root's launch restore of the target's
                // parked slot.
                guard let self else { return nil }
                await self.root.auth.coordinator.awaitBootstrapped()
                return self.root.auth.coordinator.currentUser
            },
            promptSignIn: { [weak self] in
                // iOS has no modal sign-in prompt: the rebuilt tree already
                // shows SignInView, so this just awaits whoever signs in
                // through it. NO auto-timeout — the establishing banner's
                // revert affordance is the escape hatch.
                await self?.waitForPromptedSignIn()
            },
            cancelSignInPrompt: { [weak self] in
                self?.cancelSignInPromptWait()
            },
            signOutEstablishedSession: { [weak self] in
                // The REAL sign-out chain, under the CURRENT (target)
                // defaults so revoking an ineligible session hits the
                // target's backend: the hook fences iroh + push teardown and
                // receives auth's captured tokens for the bounded server tail.
                guard let root = self?.root else { return }
                root.diagnosticLog.recordAppEvent(.authSignOutStarted)
                let serverTeardown = root.signOutHook.begin()
                await root.auth.coordinator.signOut(onSignedOut: serverTeardown)
                let stillAuthenticated = root.auth.coordinator.isAuthenticated
                root.diagnosticLog.recordAppEvent(
                    stillAuthenticated ? .authSignOutFailed : .authSignOutSucceeded,
                    failure: stillAuthenticated ? .protocolViolation : nil
                )
            },
            isEligible: { user in
                CMUXBackendEnvironmentSwitchGate.allows(user) || Self.isDebugBuild
            },
            signInPromptFailure: {
                // The iOS prompt only ever ends through requestRevert()/
                // cancelSignInPrompt (there is no bounded attempt that can
                // time out or fail — SignInView's own errors keep the wait
                // alive until a sign-in succeeds), so a nil prompt result is
                // always a cancellation. `.failed` is unreachable on iOS.
                .cancelled
            }
        )
    }

    /// Await the next signed-in user on the CURRENT (rebuilt) coordinator,
    /// holding the wait so ``cancelSignInPromptWait()`` can resolve it as
    /// cancelled. `waitForNextSignedInUser()` returns the current user
    /// immediately when the launch restore already established one.
    private func waitForPromptedSignIn() async -> CMUXAuthUser? {
        signInPromptWait?.cancel()
        let coordinator = root.auth.coordinator
        let wait = Task { @MainActor in
            await coordinator.waitForNextSignedInUser()
        }
        signInPromptWait = wait
        let user = await wait.value
        if signInPromptWait == wait {
            signInPromptWait = nil
        }
        return user
    }

    /// The transaction's `cancelSignInPrompt` step: cancelling the held task
    /// terminates the identity-stream iteration, so the in-flight
    /// `promptSignIn` resolves `nil` and the run reverts.
    private func cancelSignInPromptWait() {
        signInPromptWait?.cancel()
        signInPromptWait = nil
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
