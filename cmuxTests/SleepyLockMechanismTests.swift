import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the Sleepy Mode "Lock Mac" button.
///
/// The button shelled out to a `CGSession -suspend` tool that no longer ships
/// on macOS 26 (it is still present on the macOS 15 build fleet, which is why
/// CI never saw it). The launch error was discarded by a `try?`, so the button
/// silently did nothing.
@Suite("Sleepy Mode lock mechanism")
struct SleepyLockMechanismTests {
    /// One invocation the controls asked the system to perform.
    ///
    /// Arguments are recorded too: launching `CGSession` *without* `-suspend`
    /// would exit cleanly while locking nothing, which a tool-only assertion
    /// would miss.
    private struct Invocation: Sendable, Equatable {
        /// Absolute path of the executable that was asked to run.
        let tool: String
        /// Arguments it was invoked with.
        let args: [String]
    }

    /// Records what a `SleepyPowerControls` asked the system to do, and lets a
    /// test decide which mechanisms are available.
    ///
    /// A lock-guarded class rather than an actor, because `SleepyCommandRunning`
    /// declares `nonisolated` requirements that actor-isolated members cannot
    /// satisfy.
    private final class FakeRunner: SleepyCommandRunning, @unchecked Sendable {
        /// Guards the recorded state, which the controls touch off the main actor.
        private let lock = NSLock()
        /// Whether the fake system has the legacy `CGSession` tool installed.
        private let toolExists: Bool
        /// Whether that tool reports a zero exit status.
        private let legacyExitsZero: Bool
        /// Whether the in-process lock fallback is available.
        private let lockScreenSucceeds: Bool
        /// Commands the controls asked to run, in order.
        private var recordedInvocations: [Invocation] = []
        /// How many times the in-process lock fallback was used.
        private var recordedLockScreenCalls = 0

        /// Creates a runner describing which lock mechanisms the "system" offers.
        ///
        /// - Parameters:
        ///   - toolExists: Whether the legacy `CGSession` tool is installed.
        ///   - legacyExitsZero: Whether that tool exits successfully.
        ///   - lockScreenSucceeds: Whether the in-process lock is available.
        init(toolExists: Bool, legacyExitsZero: Bool = true, lockScreenSucceeds: Bool = true) {
            self.toolExists = toolExists
            self.legacyExitsZero = legacyExitsZero
            self.lockScreenSucceeds = lockScreenSucceeds
        }

        /// Every command invocation recorded so far, in order.
        var invocations: [Invocation] {
            lock.withLock { recordedInvocations }
        }

        /// How many times the in-process lock was used.
        var lockScreenCalls: Int {
            lock.withLock { recordedLockScreenCalls }
        }

        /// Reports whether the fake "system" has `tool` installed.
        nonisolated func canRun(_ tool: String) async -> Bool { toolExists }

        /// Records a fire-and-forget invocation.
        @discardableResult
        nonisolated func run(_ tool: String, _ args: [String]) async -> Bool {
            lock.withLock { recordedInvocations.append(Invocation(tool: tool, args: args)) }
            return legacyExitsZero
        }

        /// Records an invocation that the caller waits on for an exit status.
        @discardableResult
        nonisolated func runAwaitingExit(_ tool: String, _ args: [String]) async -> Bool {
            lock.withLock { recordedInvocations.append(Invocation(tool: tool, args: args)) }
            return legacyExitsZero
        }

        /// Unused by these tests; no command output is needed.
        nonisolated func capture(_ tool: String, _ args: [String]) async -> String? { nil }

        /// Unused by these tests; no privileged command is issued.
        @discardableResult
        nonisolated func runPrivileged(_ tool: String, _ args: [String]) async -> Bool { true }

        /// Records use of the in-process lock fallback.
        @discardableResult
        nonisolated func lockScreen() async -> Bool {
            lock.withLock { recordedLockScreenCalls += 1 }
            return lockScreenSucceeds
        }
    }

    /// The invocation a working lock must make on systems that still ship the tool.
    private static let expectedLegacyCall = Invocation(
        tool: SleepyPowerControls.legacyLockTool,
        args: ["-suspend"]
    )

    /// Builds controls wired to `runner` with isolated defaults.
    ///
    /// - Parameter runner: The fake system the controls should drive.
    /// - Returns: Controls under test.
    private func makeControls(_ runner: FakeRunner) async -> SleepyPowerControls {
        await MainActor.run {
            SleepyPowerControls(runner: runner, defaults: UserDefaults(suiteName: "sleepy.lock.tests." + UUID().uuidString)!)
        }
    }

    /// Apple's own tool is preferred, and invoked correctly, where it exists.
    @Test("Uses the supported CGSession tool, with -suspend, when the system ships it")
    func prefersSupportedToolWhenPresent() async throws {
        let runner = FakeRunner(toolExists: true)
        let controls = await makeControls(runner)

        #expect(await controls.lockMacNow())
        #expect(runner.invocations == [Self.expectedLegacyCall])
        // No need for the private symbol while the supported tool is available.
        #expect(runner.lockScreenCalls == 0)
    }

    /// The macOS 26 case: the tool is gone, so the in-process lock must run.
    @Test("Falls back to the in-process lock when the tool was removed")
    func fallsBackWhenToolMissing() async throws {
        let runner = FakeRunner(toolExists: false)
        let controls = await makeControls(runner)

        #expect(await controls.lockMacNow())
        // The missing tool must not even be launched, and the lock must happen.
        #expect(runner.invocations.isEmpty)
        #expect(runner.lockScreenCalls == 1)
    }

    /// A tool that starts and then fails has locked nothing.
    @Test("Falls back when the tool exists but exits non-zero")
    func fallsBackWhenLegacyExitsNonZero() async throws {
        let runner = FakeRunner(toolExists: true, legacyExitsZero: false)
        let controls = await makeControls(runner)

        #expect(await controls.lockMacNow())
        // The legacy command must have been attempted with -suspend first.
        #expect(runner.invocations == [Self.expectedLegacyCall])
        #expect(runner.lockScreenCalls == 1)
    }

    /// With nothing available the caller must learn the lock did not happen.
    @Test("Reports failure when no lock mechanism is available")
    func reportsFailureWhenNothingAvailable() async throws {
        let runner = FakeRunner(toolExists: false, lockScreenSucceeds: false)
        let controls = await makeControls(runner)

        // The UI relies on this to say the lock failed instead of looking inert.
        #expect(await controls.lockMacNow() == false)
    }
}
