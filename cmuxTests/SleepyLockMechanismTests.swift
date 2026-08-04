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
    /// One invocation the controls asked the system to perform. Arguments are
    /// recorded too: launching `CGSession` *without* `-suspend` would exit
    /// cleanly while locking nothing, which a tool-only assertion would miss.
    private struct Invocation: Sendable, Equatable {
        let tool: String
        let args: [String]
    }

    /// Records what a `SleepyPowerControls` asked the system to do, and lets a
    /// test decide which mechanisms are available.
    private actor FakeRunner: SleepyCommandRunning {
        private let toolExists: Bool
        private let legacyExitsZero: Bool
        private let lockScreenSucceeds: Bool
        private(set) var invocations: [Invocation] = []
        private(set) var lockScreenCalls = 0

        init(toolExists: Bool, legacyExitsZero: Bool = true, lockScreenSucceeds: Bool = true) {
            self.toolExists = toolExists
            self.legacyExitsZero = legacyExitsZero
            self.lockScreenSucceeds = lockScreenSucceeds
        }

        func canRun(_ tool: String) async -> Bool { toolExists }

        @discardableResult
        func run(_ tool: String, _ args: [String]) async -> Bool {
            invocations.append(Invocation(tool: tool, args: args))
            return legacyExitsZero
        }

        @discardableResult
        func runAwaitingExit(_ tool: String, _ args: [String]) async -> Bool {
            invocations.append(Invocation(tool: tool, args: args))
            return legacyExitsZero
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

    /// The invocation a working lock must make on systems that still ship the tool.
    private static let expectedLegacyCall = Invocation(
        tool: SleepyPowerControls.legacyLockTool,
        args: ["-suspend"]
    )

    private func makeControls(_ runner: FakeRunner) async -> SleepyPowerControls {
        await MainActor.run {
            SleepyPowerControls(runner: runner, defaults: UserDefaults(suiteName: "sleepy.lock.tests." + UUID().uuidString)!)
        }
    }

    @Test("Uses the supported CGSession tool, with -suspend, when the system ships it")
    func prefersSupportedToolWhenPresent() async throws {
        let runner = FakeRunner(toolExists: true)
        let controls = await makeControls(runner)

        #expect(await controls.lockMacNow())
        #expect(await runner.invocations == [Self.expectedLegacyCall])
        // No need for the private symbol while Apple's tool is available.
        #expect(await runner.lockScreenCalls == 0)
    }

    @Test("Falls back to the in-process lock when the tool was removed")
    func fallsBackWhenToolMissing() async throws {
        let runner = FakeRunner(toolExists: false)
        let controls = await makeControls(runner)

        #expect(await controls.lockMacNow())
        // The missing tool must not even be launched, and the lock must happen.
        #expect(await runner.invocations.isEmpty)
        #expect(await runner.lockScreenCalls == 1)
    }

    @Test("Falls back when the tool exists but exits non-zero")
    func fallsBackWhenLegacyExitsNonZero() async throws {
        let runner = FakeRunner(toolExists: true, legacyExitsZero: false)
        let controls = await makeControls(runner)

        #expect(await controls.lockMacNow())
        // A process that starts and fails has locked nothing: the legacy command
        // must have been attempted with -suspend, then the fallback used.
        #expect(await runner.invocations == [Self.expectedLegacyCall])
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
