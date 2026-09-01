import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct CaffeineControllerTests {
    @Test
    func activityIsAcquiredAndReleasedExactlyOncePerTransition() {
        let token = NSObject()
        var beginCount = 0
        var endedTokens: [ObjectIdentifier] = []
        var stateChanges: [Bool] = []
        let controller = CaffeineController(
            beginActivity: {
                beginCount += 1
                return token
            },
            endActivity: { activity in
                endedTokens.append(ObjectIdentifier(activity))
            }
        )
        controller.onStateChange = { stateChanges.append($0) }

        controller.setEnabled(true)
        controller.setEnabled(true)

        #expect(controller.isEnabled)
        #expect(beginCount == 1)
        #expect(endedTokens.isEmpty)
        #expect(stateChanges == [true])

        controller.setEnabled(false)
        controller.setEnabled(false)

        #expect(!controller.isEnabled)
        #expect(endedTokens == [ObjectIdentifier(token)])
        #expect(stateChanges == [true, false])
    }

    @Test
    func toggleUsesTheSameStateTransitionPath() {
        let token = NSObject()
        var releaseCount = 0
        let controller = CaffeineController(
            beginActivity: { token },
            endActivity: { _ in releaseCount += 1 }
        )

        controller.toggle()
        #expect(controller.isEnabled)

        controller.toggle()
        #expect(!controller.isEnabled)
        #expect(releaseCount == 1)
    }

    @MainActor
    private final class FakeLockScreen: CaffeineLockScreenPresenting {
        var isPresented = false
        var presentCount = 0
        var dismissCount = 0

        func present() {
            isPresented = true
            presentCount += 1
        }

        func dismiss() {
            isPresented = false
            dismissCount += 1
        }
    }

    private func makeController(preference: @escaping () -> Bool, lockScreen: FakeLockScreen) -> CaffeineController {
        let controller = CaffeineController(
            beginActivity: { NSObject() },
            endActivity: { _ in }
        )
        controller.lockScreenPresenter = lockScreen
        controller.lockScreenPreference = preference
        return controller
    }

    @Test
    func preferenceShowsLockScreenForTheFullCaffeineWindow() {
        let lockScreen = FakeLockScreen()
        let controller = makeController(preference: { true }, lockScreen: lockScreen)

        controller.setEnabled(true)
        #expect(lockScreen.isPresented)
        #expect(lockScreen.presentCount == 1)

        controller.setEnabled(false)
        #expect(!lockScreen.isPresented)
        #expect(lockScreen.dismissCount == 1)
    }

    @Test
    func preferenceOffKeepsTheScreenUncoveredUnlessOverridden() {
        let lockScreen = FakeLockScreen()
        let controller = makeController(preference: { false }, lockScreen: lockScreen)

        controller.setEnabled(true)
        #expect(!lockScreen.isPresented)

        controller.setEnabled(false)
        controller.setEnabled(true, lockScreen: true)
        #expect(lockScreen.isPresented)
    }

    @Test
    func explicitNoLockScreenBeatsThePreference() {
        let lockScreen = FakeLockScreen()
        let controller = makeController(preference: { true }, lockScreen: lockScreen)

        controller.setEnabled(true, lockScreen: false)
        #expect(!lockScreen.isPresented)
    }

    @Test
    func lockScreenOverrideAppliesWhileAlreadyCaffeinated() {
        let lockScreen = FakeLockScreen()
        let controller = makeController(preference: { false }, lockScreen: lockScreen)

        controller.setEnabled(true)
        controller.setEnabled(true, lockScreen: true)
        #expect(lockScreen.isPresented)

        controller.setEnabled(true, lockScreen: false)
        #expect(!lockScreen.isPresented)
    }

    @Test
    func redundantEnableDoesNotResurrectAManuallyDismissedLockScreen() {
        let lockScreen = FakeLockScreen()
        let controller = makeController(preference: { true }, lockScreen: lockScreen)

        controller.setEnabled(true)
        lockScreen.isPresented = false // user pressed a key; overlay exited
        controller.noteLockScreenDismissed()

        controller.setEnabled(true)
        #expect(!lockScreen.isPresented)
        #expect(lockScreen.presentCount == 1)

        controller.setEnabled(false)
        #expect(lockScreen.dismissCount == 0)
    }

    @Test
    func userOwnedLockScreenSurvivesCaffeineEnd() {
        let lockScreen = FakeLockScreen()
        let controller = makeController(preference: { true }, lockScreen: lockScreen)

        lockScreen.isPresented = true // user started Sleepy Mode themselves

        controller.setEnabled(true)
        #expect(lockScreen.presentCount == 0)

        controller.setEnabled(false)
        #expect(lockScreen.isPresented)
        #expect(lockScreen.dismissCount == 0)
    }

    @Test
    func lockMacFiresOnEnableAndImpliesTheCover() {
        let lockScreen = FakeLockScreen()
        let controller = makeController(preference: { false }, lockScreen: lockScreen)
        var lockMacCount = 0
        controller.lockMacAction = { lockMacCount += 1 }

        controller.setEnabled(true, lockMac: true)
        #expect(lockMacCount == 1)
        #expect(lockScreen.isPresented)

        controller.setEnabled(false)
        #expect(lockMacCount == 1)
    }

    @Test
    func lockMacPreferenceAppliesOnTheEnableTransitionOnly() {
        let lockScreen = FakeLockScreen()
        let controller = makeController(preference: { false }, lockScreen: lockScreen)
        var lockMacCount = 0
        controller.lockMacPreference = { true }
        controller.lockMacAction = { lockMacCount += 1 }

        controller.setEnabled(true)
        #expect(lockMacCount == 1)

        controller.setEnabled(true)
        #expect(lockMacCount == 1)

        controller.setEnabled(false)
        controller.setEnabled(true, lockMac: false)
        #expect(lockMacCount == 1)
    }

    @Test
    func explicitNoCoverKeepsLockMacUncovered() {
        let lockScreen = FakeLockScreen()
        let controller = makeController(preference: { false }, lockScreen: lockScreen)
        var lockMacCount = 0
        controller.lockMacAction = { lockMacCount += 1 }

        controller.setEnabled(true, lockScreen: false, lockMac: true)
        #expect(lockMacCount == 1)
        #expect(!lockScreen.isPresented)
    }

    @Test
    func lockScreenStartedAfterManualDismissBelongsToTheUser() {
        let lockScreen = FakeLockScreen()
        let controller = makeController(preference: { true }, lockScreen: lockScreen)

        controller.setEnabled(true)
        lockScreen.isPresented = false // user dismissed the caffeine lock screen
        controller.noteLockScreenDismissed()
        lockScreen.isPresented = true // then started Sleepy Mode manually

        controller.setEnabled(false)
        #expect(lockScreen.isPresented)
        #expect(lockScreen.dismissCount == 0)
    }
}
