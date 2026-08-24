import CMUXAuthCore
import CmuxAuthRuntime
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXBackendEnvironmentSelection {
    /// Compact event label: `lane(production)`, `explicit(staging)`, …
    fileprivate var eventLabel: String {
        switch self {
        case .lane(let resolves): "lane(\(resolves.rawValue))"
        case .explicit(let choice): "explicit(\(choice.rawValue))"
        }
    }
}

/// Fake step wiring for ``MacBackendEnvironmentSwitchController``: records
/// the step order, stands in for `MobileHostService.stop()`/`start()` around
/// the quiesce window, persists the selection into a scratch defaults suite
/// exactly as the production wiring does (explicit → storeChoice, lane →
/// clearChoice, both arming the rebuild marker), and can park the
/// park/prompt steps on continuations so a test can observe the world
/// mid-switch.
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

    func steps(
        active: CMUXBackendEnvironmentSelection = .lane(resolves: .production)
    ) -> BackendEnvironmentSwitchTransaction.Steps {
        BackendEnvironmentSwitchTransaction.Steps(
            activeSelection: { active },
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
            storeSelection: { selection in
                // Production wiring: explicit choices write the tri-state
                // key, lane targets clear it, and BOTH arm the one-shot
                // rebuild marker.
                switch selection {
                case .explicit(let choice):
                    choice.storeChoice(in: self.defaults)
                case .lane:
                    CMUXBackendEnvironmentOverride.clearChoice(in: self.defaults)
                }
                CMUXBackendEnvironmentSwitchRebuildMarker.arm(in: self.defaults)
                self.events.append("store(\(selection.eventLabel))")
            },
            rebuild: { selection in
                // Production wiring: AppDelegate.adoptRebuiltAuth(_:), which
                // ends with MobileHostService.shared.start().
                self.events.append("rebuild(\(selection.eventLabel))")
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

        let run = Task { await controller.switchEnvironment(to: .explicit(.staging)) }
        while !recorder.parkParked { await Task.yield() }

        // Mid-park: still the old selection on disk, phase visible.
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

        await controller.switchEnvironment(to: .explicit(.staging))

        #expect(recorder.events == [
            "park",
            "mobileHost.stop",
            "store(explicit(staging))",
            "rebuild(explicit(staging))",
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

        let run = Task { await controller.switchEnvironment(to: .explicit(.staging)) }
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

    @Test("requestRevert during the sign-in wait cancels the prompt and reverts to the LANE")
    func requestRevertCancelsThePromptAndRevertsToTheLane() async {
        let recorder = SwitchStepsRecorder()
        defer { recorder.cleanUp() }
        recorder.parkThePrompt = true
        let controller = MacBackendEnvironmentSwitchController(steps: recorder.steps())

        let run = Task { await controller.switchEnvironment(to: .explicit(.staging)) }
        while !recorder.promptParked { await Task.yield() }
        #expect(controller.phase == .establishing)

        controller.requestRevert()
        await run.value

        #expect(recorder.events.contains("cancelSignInPrompt"))
        #expect(controller.phase == .finished(.reverted(.signInCancelled)))
        // The revert re-committed the ORIGINAL selection — the lane, whose
        // store step CLEARS the tri-state key — and re-armed the rebuild
        // marker.
        #expect(recorder.events.contains("store(lane(production))"))
        #expect(recorder.storedOverrideRawValue == nil)
        #expect(recorder.rebuildMarkerArmed)
    }

    @Test("Switching back to the lane never consults the gate or the prompt")
    func switchBackToTheLaneNeverPrompts() async {
        let recorder = SwitchStepsRecorder()
        defer { recorder.cleanUp() }
        recorder.restoredUsers = [nil]
        CMUXBackendEnvironmentOverride.staging.storeChoice(in: recorder.defaults)
        let controller = MacBackendEnvironmentSwitchController(
            steps: recorder.steps(active: .explicit(.staging))
        )

        await controller.switchEnvironment(to: .lane(resolves: .production))

        #expect(controller.phase == .finished(.switched))
        #expect(!recorder.events.contains("promptSignIn"))
        #expect(!recorder.events.contains("signOutEstablished"))
        // The lane target cleared the tri-state key.
        #expect(recorder.storedOverrideRawValue == nil)
        #expect(recorder.rebuildMarkerArmed)
    }

    @Test("An explicit production pick WRITES the key (tri-state, not removal)")
    func explicitProductionWritesTheKey() async {
        // On a non-production lane the picker's "Production" is an explicit
        // wholesale choice; the controller must persist it, not clear it.
        let recorder = SwitchStepsRecorder()
        defer { recorder.cleanUp() }
        recorder.restoredUsers = [nil]
        let controller = MacBackendEnvironmentSwitchController(
            steps: recorder.steps(active: .lane(resolves: .staging))
        )

        await controller.switchEnvironment(to: .explicit(.production))

        #expect(controller.phase == .finished(.switched))
        #expect(recorder.storedOverrideRawValue == "production")
        #expect(!recorder.events.contains("promptSignIn"))
    }

    // MARK: - Selection-identity guard matrix

    @Test("GUARD: lane(staging) → explicit(staging) RUNS")
    func laneStagingToExplicitStagingRuns() async {
        // The Part F unblock: a staging-baked build explicitly picking
        // Staging is a real switch even though the resolved environment
        // does not change (the choice key gets written, gating attaches).
        let recorder = SwitchStepsRecorder()
        defer { recorder.cleanUp() }
        recorder.restoredUsers = [Self.teamUser]
        recorder.eligibleUserIDs = [Self.teamUser.id]
        let controller = MacBackendEnvironmentSwitchController(
            steps: recorder.steps(active: .lane(resolves: .staging))
        )

        await controller.switchEnvironment(to: .explicit(.staging))

        #expect(controller.phase == .finished(.switched))
        #expect(recorder.storedOverrideRawValue == "staging")
    }

    @Test("GUARD: explicit(staging) → explicit(staging) refuses")
    func explicitStagingToSameRefuses() async {
        let recorder = SwitchStepsRecorder()
        defer { recorder.cleanUp() }
        let controller = MacBackendEnvironmentSwitchController(
            steps: recorder.steps(active: .explicit(.staging))
        )

        await controller.switchEnvironment(to: .explicit(.staging))

        #expect(recorder.events.isEmpty)
        #expect(controller.phase == .idle)
    }

    @Test("GUARD: lane → lane refuses")
    func laneToLaneRefuses() async {
        let recorder = SwitchStepsRecorder()
        defer { recorder.cleanUp() }
        let controller = MacBackendEnvironmentSwitchController(
            steps: recorder.steps(active: .lane(resolves: .production))
        )

        await controller.switchEnvironment(to: .lane(resolves: .production))

        #expect(recorder.events.isEmpty)
        #expect(controller.phase == .idle)
    }
}
