import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the Sleepy Mode "Lock Mac" button.
///
/// Apple removed `User.menu` from `Menu Extras`, so the `CGSession -suspend`
/// tool the button shelled out to no longer exists on macOS 26 (it is still
/// present on the macOS 15 build fleet, which is why CI never saw it). The
/// launch error was discarded by a `try?`, so the button silently did nothing.
@Suite("Sleepy Mode lock mechanism")
struct SleepyLockMechanismTests {
    /// Records what a `SleepyPowerControls` asked the system to do, and lets a
    /// test decide which mechanisms are available.
    private actor FakeRunner: SleepyCommandRunning {
        private let toolExists: Bool
        private let launchSucceeds: Bool
        private let lockScreenSucceeds: Bool
        private(set) var launchedTools: [String] = []
        private(set) var lockScreenCalls = 0

        init(toolExists: Bool, launchSucceeds: Bool = true, lockScreenSucceeds: Bool = true) {
            self.toolExists = toolExists
            self.launchSucceeds = launchSucceeds
            self.lockScreenSucceeds = lockScreenSucceeds
        }

        func canRun(_ tool: String) async -> Bool { toolExists }

        @discardableResult
        func run(_ tool: String, _ args: [String]) async -> Bool {
            launchedTools.append(tool)
            return launchSucceeds
        }

        func capture(_ tool: String, _ args: [String]) async -> String? { nil }

        @discardableResult
        func runPrivileged(_ tool: String, _ args: [String]) async -> Bool { true }

        @discardableResult
        func lockScreen() async -> Bool {
            lockScreenCalls += 1
            return lockScreenSucceeds
        }
    }

    private func makeControls(_ runner: FakeRunner) async -> SleepyPowerControls {
        await MainActor.run {
            SleepyPowerControls(runner: runner, defaults: UserDefaults(suiteName: "sleepy.lock.tests." + UUID().uuidString)!)
        }
    }

    @Test("Uses the supported CGSession tool when the system still ships it")
    func prefersSupportedToolWhenPresent() async throws {
        let runner = FakeRunner(toolExists: true)
        let controls = await makeControls(runner)

        #expect(await controls.lockMacNow())
        #expect(await runner.launchedTools == [SleepyPowerControls.legacyLockTool])
        // No need for the private symbol while Apple's tool is available.
        #expect(await runner.lockScreenCalls == 0)
    }

    @Test("Falls back to the in-process lock when the tool was removed")
    func fallsBackWhenToolMissing() async throws {
        let runner = FakeRunner(toolExists: false)
        let controls = await makeControls(runner)

        #expect(await controls.lockMacNow())
        // The missing tool must not even be launched, and the lock must happen.
        #expect(await runner.launchedTools.isEmpty)
        #expect(await runner.lockScreenCalls == 1)
    }

    @Test("Falls back when the tool exists but cannot be launched")
    func fallsBackWhenLaunchFails() async throws {
        let runner = FakeRunner(toolExists: true, launchSucceeds: false)
        let controls = await makeControls(runner)

        #expect(await controls.lockMacNow())
        #expect(await runner.lockScreenCalls == 1)
    }

    @Test("Reports failure when no lock mechanism is available")
    func reportsFailureWhenNothingAvailable() async throws {
        let runner = FakeRunner(toolExists: false, lockScreenSucceeds: false)
        let controls = await makeControls(runner)

        // The UI relies on this to say the lock failed instead of looking inert.
        #expect(await controls.lockMacNow() == false)
    }
}
