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
/// and can park the sign-out step on a continuation so a test can observe
/// the world mid-switch.
@MainActor
private final class SwitchStepsRecorder {
    private(set) var events: [String] = []
    let defaults: UserDefaults
    private let suiteName: String

    private var signOutGate: CheckedContinuation<Void, Never>?
    var parkSignOut = false
    private(set) var signOutParked = false

    init() {
        suiteName = "test.cmux.backendEnvironmentSwitch.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func releaseSignOut() {
        signOutParked = false
        signOutGate?.resume()
        signOutGate = nil
    }

    var storedOverrideRawValue: String? {
        defaults.string(forKey: CMUXBackendEnvironmentOverride.defaultsKey)
    }

    func steps() -> BackendEnvironmentSwitchTransaction.Steps {
        BackendEnvironmentSwitchTransaction.Steps(
            isPinnedByBuild: { false },
            activeEnvironment: { .production },
            signOut: {
                self.events.append("signOut")
                if self.parkSignOut {
                    self.signOutParked = true
                    await withCheckedContinuation { self.signOutGate = $0 }
                }
            },
            quiesce: {
                // Production wiring: MobileHostService.shared.stop().
                self.events.append("mobileHost.stop")
            },
            storeOverride: { override in
                override.store(in: self.defaults)
                self.events.append("store")
            },
            rebuild: { _ in
                // Production wiring: AppDelegate.adoptRebuiltAuth(_:), which
                // ends with MobileHostService.shared.start().
                self.events.append("rebuild")
                self.events.append("mobileHost.start")
            }
        )
    }
}

@MainActor
@Suite("MacBackendEnvironmentSwitchController")
struct MacBackendEnvironmentSwitchControllerTests {
    @Test("The defaults key is untouched until sign-out completes")
    func defaultsKeyUntouchedUntilSignOutCompletes() async {
        let recorder = SwitchStepsRecorder()
        defer { recorder.cleanUp() }
        recorder.parkSignOut = true
        let controller = MacBackendEnvironmentSwitchController(steps: recorder.steps())

        let run = Task { await controller.switchEnvironment(to: .staging) }
        while !recorder.signOutParked { await Task.yield() }

        // Mid-sign-out: still the old environment on disk, phase visible.
        #expect(recorder.storedOverrideRawValue == nil)
        #expect(controller.phase == .signingOut)

        recorder.releaseSignOut()
        await run.value

        #expect(recorder.storedOverrideRawValue == "staging")
        #expect(controller.phase == .finished)
    }

    @Test("MobileHostService stops before the commit and restarts after the rebuild")
    func mobileHostStopStartBracketTheQuiesceWindow() async {
        let recorder = SwitchStepsRecorder()
        defer { recorder.cleanUp() }
        let controller = MacBackendEnvironmentSwitchController(steps: recorder.steps())

        await controller.switchEnvironment(to: .staging)

        #expect(recorder.events == [
            "signOut",
            "mobileHost.stop",
            "store",
            "rebuild",
            "mobileHost.start",
        ])
    }

    @Test("isSwitching covers the whole run window")
    func isSwitchingReflectsTheRunWindow() async {
        let recorder = SwitchStepsRecorder()
        defer { recorder.cleanUp() }
        recorder.parkSignOut = true
        let controller = MacBackendEnvironmentSwitchController(steps: recorder.steps())
        #expect(!controller.isSwitching)

        let run = Task { await controller.switchEnvironment(to: .staging) }
        while !recorder.signOutParked { await Task.yield() }

        // HostAccountFlow ORs this into isWorkingOnAuth, disabling the
        // account/auth entrypoints for the whole switch window.
        #expect(controller.isSwitching)

        recorder.releaseSignOut()
        await run.value

        #expect(!controller.isSwitching)
        #expect(controller.phase == .finished)
        controller.reset()
        #expect(controller.phase == .idle)
    }
}
