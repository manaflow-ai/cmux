import XCTest
import IOKit.pwr_mgt

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MacSleepPreventionTests: XCTestCase {
    func testPreferenceDefaultsToOff() {
        let suiteName = "MacSleepPreventionSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertFalse(MacSleepPreventionSettings.isEnabled(defaults: defaults))

        MacSleepPreventionSettings.setEnabled(true, defaults: defaults)
        XCTAssertTrue(MacSleepPreventionSettings.isEnabled(defaults: defaults))

        MacSleepPreventionSettings.setEnabled(false, defaults: defaults)
        XCTAssertFalse(MacSleepPreventionSettings.isEnabled(defaults: defaults))
    }

    func testControllerAcquiresAndReleasesAssertion() {
        let suiteName = "MacSleepPreventionControllerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var acquiredReasons: [String] = []
        var releasedAssertions: [IOPMAssertionID] = []
        let controller = MacSleepPreventionController(
            defaults: defaults,
            acquireAssertion: { reason in
                acquiredReasons.append(reason)
                return .success(IOPMAssertionID(42))
            },
            releaseAssertion: { assertionID in
                releasedAssertions.append(assertionID)
                return kIOReturnSuccess
            }
        )

        XCTAssertFalse(controller.isEnabled)

        XCTAssertTrue(controller.setEnabled(true))
        XCTAssertTrue(MacSleepPreventionSettings.isEnabled(defaults: defaults))
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(acquiredReasons.count, 1)
        XCTAssertFalse(acquiredReasons[0].isEmpty)

        XCTAssertTrue(controller.setEnabled(true))
        XCTAssertEqual(acquiredReasons.count, 1)

        XCTAssertTrue(controller.setEnabled(false))
        XCTAssertFalse(MacSleepPreventionSettings.isEnabled(defaults: defaults))
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(releasedAssertions, [IOPMAssertionID(42)])
    }

    func testControllerSyncsFromDefaults() {
        let suiteName = "MacSleepPreventionControllerSyncTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var acquireCount = 0
        var releasedAssertions: [IOPMAssertionID] = []
        let controller = MacSleepPreventionController(
            defaults: defaults,
            acquireAssertion: { _ in
                acquireCount += 1
                return .success(IOPMAssertionID(99))
            },
            releaseAssertion: { assertionID in
                releasedAssertions.append(assertionID)
                return kIOReturnSuccess
            }
        )

        defaults.set(true, forKey: MacSleepPreventionSettings.preventSystemSleepKey)
        controller.syncToSettings()
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(acquireCount, 1)

        controller.syncToSettings()
        XCTAssertEqual(acquireCount, 1)

        defaults.set(false, forKey: MacSleepPreventionSettings.preventSystemSleepKey)
        controller.syncToSettings()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(releasedAssertions, [IOPMAssertionID(99)])
    }

    func testControllerClearsSettingWhenAssertionFails() {
        let suiteName = "MacSleepPreventionControllerFailureTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let controller = MacSleepPreventionController(
            defaults: defaults,
            acquireAssertion: { _ in .failure(kIOReturnError) },
            releaseAssertion: { _ in kIOReturnSuccess }
        )

        XCTAssertFalse(controller.setEnabled(true))
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(MacSleepPreventionSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(controller.lastError, kIOReturnError)
    }

    func testLockScreenAndPreventSleepEnablesAssertionBeforeLocking() {
        let sleepController = FakeSleepPreventionController()
        let screenLocker = FakeScreenLocker()

        XCTAssertTrue(
            MacSleepPreventionActions.lockScreenAndPreventSleep(
                sleepPreventionController: sleepController,
                screenLocker: screenLocker
            )
        )

        XCTAssertEqual(sleepController.events, ["set:true"])
        XCTAssertEqual(screenLocker.events, ["lock"])
        XCTAssertTrue(sleepController.isEnabled)
    }

    func testLockScreenAndPreventSleepRollsBackWhenLockFails() {
        let sleepController = FakeSleepPreventionController()
        let screenLocker = FakeScreenLocker(shouldLock: false)

        XCTAssertFalse(
            MacSleepPreventionActions.lockScreenAndPreventSleep(
                sleepPreventionController: sleepController,
                screenLocker: screenLocker
            )
        )

        XCTAssertEqual(sleepController.events, ["set:true", "set:false"])
        XCTAssertEqual(screenLocker.events, ["lock"])
        XCTAssertFalse(sleepController.isEnabled)
    }

    func testLockScreenAndPreventSleepKeepsExistingAssertionWhenLockFails() {
        let sleepController = FakeSleepPreventionController(isEnabled: true)
        let screenLocker = FakeScreenLocker(shouldLock: false)

        XCTAssertFalse(
            MacSleepPreventionActions.lockScreenAndPreventSleep(
                sleepPreventionController: sleepController,
                screenLocker: screenLocker
            )
        )

        XCTAssertEqual(sleepController.events, ["set:true"])
        XCTAssertTrue(sleepController.isEnabled)
    }

    func testScreenLockerRecordsCommandFailure() {
        enum LockError: Error {
            case failed
        }

        let screenLocker = MacScreenLocker {
            throw LockError.failed
        }

        XCTAssertFalse(screenLocker.lockScreen())
        XCTAssertNotNil(screenLocker.lastErrorDescription)
    }
}

@MainActor
private final class FakeSleepPreventionController: MacSleepPreventionControlling {
    private(set) var isEnabled: Bool
    private(set) var lastError: IOReturn?
    private(set) var events: [String] = []

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func syncToSettings() {}

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        events.append("set:\(enabled)")
        isEnabled = enabled
        return true
    }
}

@MainActor
private final class FakeScreenLocker: MacScreenLocking {
    private let shouldLock: Bool
    private(set) var lastErrorDescription: String?
    private(set) var events: [String] = []

    init(shouldLock: Bool = true) {
        self.shouldLock = shouldLock
    }

    @discardableResult
    func lockScreen() -> Bool {
        events.append("lock")
        lastErrorDescription = shouldLock ? nil : "failed"
        return shouldLock
    }
}
