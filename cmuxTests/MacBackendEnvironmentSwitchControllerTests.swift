import CMUXAuthCore
import CmuxAuthRuntime
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Fake step wiring for ``MacBackendEnvironmentSwitchController``: records
/// the step order, stands in for `MobileHostService.stop()`/`start()` around
/// the quiesce window, persists the override into a scratch defaults suite,
/// and can park the park/prompt steps on continuations so a test can observe
/// the world mid-switch.
@MainActor
private final class SwitchStepsRecorder {
    private(set) var events: [String] = []
    let defaults: UserDefaults
    private let suiteName: String

    /// Scripted results for `awaitRestoredUser`, consumed head-first
    /// (empty = nil; a revert's trailing restore also consumes one).
    var restoredUsers: [CMUXAuthUser?] = []
    /// Scripted result for `promptSignIn` when it is not parked.
    var promptedUser: CMUXAuthUser?
    /// Which user ids the gate treats as eligible.
    var eligibleUserIDs: Set<String> = []
    var promptFailure: BackendEnvironmentSwitchTransaction.SignInPromptFailure = .failed

    private var parkGate: CheckedContinuation<Void, Never>?
    var parkThePark = false
    private(set) var parkParked = false

    private var promptGate: CheckedContinuation<CMUXAuthUser?, Never>?
    var parkThePrompt = false
    private(set) var promptParked = false

    init() {
        suiteName = "test.cmux.backendEnvironmentSwitch.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func releasePark() {
        parkParked = false
        parkGate?.resume()
        parkGate = nil
    }

    func resolvePrompt(with user: CMUXAuthUser?) {
        promptParked = false
        promptGate?.resume(returning: user)
        promptGate = nil
    }

    var storedOverrideRawValue: String? {
        defaults.string(forKey: CMUXBackendEnvironmentOverride.defaultsKey)
    }

    var rebuildMarkerArmed: Bool {
        defaults.bool(forKey: CMUXBackendEnvironmentSwitchRebuildMarker.defaultsKey)
    }

    func steps(active: CMUXBackendEnvironmentOverride = .production)
        -> BackendEnvironmentSwitchTransaction.Steps {
        BackendEnvironmentSwitchTransaction.Steps(
            isPinnedByBuild: { false },
            activeEnvironment: { active },
            parkSession: {
                self.events.append("park")
                if self.parkThePark {
                    self.parkParked = true
                    await withCheckedContinuation { self.parkGate = $0 }
                }
            },
            quiesce: {
                // Production wiring: MobileHostService.shared.stop().
                self.events.append("mobileHost.stop")
            },
            storeOverride: { override in
                // Production wiring also arms the one-shot rebuild marker.
                override.store(in: self.defaults)
                CMUXBackendEnvironmentSwitchRebuildMarker.arm(in: self.defaults)
                self.events.append("store(\(override.rawValue))")
            },
            rebuild: { override in
                // Production wiring: AppDelegate.adoptRebuiltAuth(_:), which
                // ends with MobileHostService.shared.start().
                self.events.append("rebuild(\(override.rawValue))")
                self.events.append("mobileHost.start")
            },
            awaitRestoredUser: {
                self.events.append("awaitRestoredUser")
                guard !self.restoredUsers.isEmpty else { return nil }
                return self.restoredUsers.removeFirst()
            },
            promptSignIn: {
                self.events.append("promptSignIn")
                if self.parkThePrompt {
                    self.promptParked = true
                    return await withCheckedContinuation { self.promptGate = $0 }
                }
                return self.promptedUser
            },
            cancelSignInPrompt: {
                self.events.append("cancelSignInPrompt")
                self.resolvePrompt(with: nil)
            },
            signOutEstablishedSession: { self.events.append("signOutEstablished") },
            isEligible: { user in self.eligibleUserIDs.contains(user.id) },
            signInPromptFailure: { self.promptFailure }
        )
    }
}

@MainActor
@Suite("MacBackendEnvironmentSwitchController")
struct MacBackendEnvironmentSwitchControllerTests {
    private static let teamUser = CMUXAuthUser(
        id: "team-user",
        primaryEmail: "aziz@manaflow.ai",
        displayName: "Aziz",
        primaryEmailVerified: true
    )

    @Test("The defaults key is untouched until the park completes")
    func defaultsKeyUntouchedUntilParkCompletes() async {
        let recorder = SwitchStepsRecorder()
        defer { recorder.cleanUp() }
        recorder.parkThePark = true
        recorder.restoredUsers = [Self.teamUser]
        recorder.eligibleUserIDs = [Self.teamUser.id]
        let controller = MacBackendEnvironmentSwitchController(steps: recorder.steps())

        let run = Task { await controller.switchEnvironment(to: .staging) }
        while !recorder.parkParked { await Task.yield() }

        // Mid-park: still the old environment on disk, phase visible.
        #expect(recorder.storedOverrideRawValue == nil)
        #expect(!recorder.rebuildMarkerArmed)
        #expect(controller.phase == .parking)

        recorder.releasePark()
        await run.value

        #expect(recorder.storedOverrideRawValue == "staging")
        #expect(recorder.rebuildMarkerArmed)
        #expect(controller.phase == .finished(.switched))
    }

    @Test("MobileHostService stops before the commit and restarts after the rebuild")
    func mobileHostStopStartBracketTheQuiesceWindow() async {
        let recorder = SwitchStepsRecorder()
        defer { recorder.cleanUp() }
        recorder.restoredUsers = [Self.teamUser]
        recorder.eligibleUserIDs = [Self.teamUser.id]
        let controller = MacBackendEnvironmentSwitchController(steps: recorder.steps())

        await controller.switchEnvironment(to: .staging)

        #expect(recorder.events == [
            "park",
            "mobileHost.stop",
            "store(staging)",
            "rebuild(staging)",
            "mobileHost.start",
            "awaitRestoredUser",
        ])
    }

    @Test("isSwitching covers the whole run window")
    func isSwitchingReflectsTheRunWindow() async {
        let recorder = SwitchStepsRecorder()
        defer { recorder.cleanUp() }
        recorder.parkThePark = true
        recorder.restoredUsers = [Self.teamUser]
        recorder.eligibleUserIDs = [Self.teamUser.id]
        let controller = MacBackendEnvironmentSwitchController(steps: recorder.steps())
        #expect(!controller.isSwitching)

        let run = Task { await controller.switchEnvironment(to: .staging) }
        while !recorder.parkParked { await Task.yield() }

        // HostAccountFlow ORs this into isWorkingOnAuth, disabling the
        // account/auth entrypoints for the whole switch window.
        #expect(controller.isSwitching)

        recorder.releasePark()
        await run.value

        #expect(!controller.isSwitching)
        #expect(controller.phase == .finished(.switched))
        controller.reset()
        #expect(controller.phase == .idle)
    }

    @Test("requestRevert during the sign-in wait cancels the prompt and reverts")
    func requestRevertCancelsThePromptAndReverts() async {
        let recorder = SwitchStepsRecorder()
        defer { recorder.cleanUp() }
        recorder.parkThePrompt = true
        let controller = MacBackendEnvironmentSwitchController(steps: recorder.steps())

        let run = Task { await controller.switchEnvironment(to: .staging) }
        while !recorder.promptParked { await Task.yield() }
        #expect(controller.phase == .establishing)

        controller.requestRevert()
        await run.value

        #expect(recorder.events.contains("cancelSignInPrompt"))
        #expect(controller.phase == .finished(.reverted(.signInCancelled)))
        // The revert re-committed the previous environment (production
        // removes the key) and re-armed the rebuild marker.
        #expect(recorder.storedOverrideRawValue == nil)
        #expect(recorder.rebuildMarkerArmed)
    }

    @Test("Switching back to production never consults the gate or the prompt")
    func switchBackToProductionNeverPrompts() async {
        let recorder = SwitchStepsRecorder()
        defer { recorder.cleanUp() }
        recorder.restoredUsers = [nil]
        let controller = MacBackendEnvironmentSwitchController(
            steps: recorder.steps(active: .staging)
        )

        await controller.switchEnvironment(to: .production)

        #expect(controller.phase == .finished(.switched))
        #expect(!recorder.events.contains("promptSignIn"))
        #expect(!recorder.events.contains("signOutEstablished"))
        #expect(recorder.storedOverrideRawValue == nil)
    }
}
