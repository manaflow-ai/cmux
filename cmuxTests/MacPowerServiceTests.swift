import Testing
@testable import cmux

@MainActor
@Suite struct MacPowerServiceTests {
    @Test func independentKeepAwakeAndLowPowerStateCompose() async throws {
        let holder = FakePowerAssertionHolder()
        let controls = FakeSleepyPowerControls()
        let service = MacPowerService(powerControls: controls, assertionHolder: holder)

        #expect(await service.status() == MacPowerStatus(
            keepAwakeEnabled: false,
            lowPowerEnabled: false
        ))
        #expect(try await service.setKeepAwake(true).keepAwakeEnabled)
        #expect(await service.setLowPowerMode(true).lowPowerEnabled)
        #expect(controls.setLowPowerCalls == [true])
        #expect(try await service.setKeepAwake(false).lowPowerEnabled)
        #expect(!holder.isEnabled)
    }

    @Test func deniedLowPowerMutationThrows() async {
        let controls = FakeSleepyPowerControls()
        controls.appliesLowPowerChanges = false
        let service = MacPowerService(
            powerControls: controls,
            assertionHolder: FakePowerAssertionHolder()
        )
        await #expect(throws: MacPowerService.ServiceError.lowPowerMutationFailed) {
            try await service.setLowPowerMode(true)
        }
        #expect(!controls.lowPowerEnabled)
    }

    @Test func displaySleepUsesSharedSleepyPath() async {
        let controls = FakeSleepyPowerControls()
        let service = MacPowerService(
            powerControls: controls,
            assertionHolder: FakePowerAssertionHolder()
        )
        await service.sleepDisplay()
        #expect(controls.sleepDisplayCalls == 1)
    }
}

@MainActor private final class FakePowerAssertionHolder: PowerAssertionHolding {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

@MainActor private final class FakeSleepyPowerControls: SleepyPowerControlling {
    var lowPowerEnabled = false
    var setLowPowerCalls: [Bool] = []
    var sleepDisplayCalls = 0
    var appliesLowPowerChanges = true

    func sleepDisplayNow() async { sleepDisplayCalls += 1 }
    func lockMacNow() async {}
    func isLowPowerOn() async -> Bool { lowPowerEnabled }
    func setLowPowerMode(_ enabled: Bool) async -> Bool {
        setLowPowerCalls.append(enabled)
        if appliesLowPowerChanges { lowPowerEnabled = enabled }
        return lowPowerEnabled
    }
}
