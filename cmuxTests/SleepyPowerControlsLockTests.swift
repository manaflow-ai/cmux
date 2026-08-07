import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Records every system effect instead of touching the machine, so these tests
/// can never lock, sleep, or reconfigure the host they run on.
private final class RecordingSleepyRunner: SleepyCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTools: [String] = []

    var ranTools: [String] {
        lock.withLock { recordedTools }
    }

    func run(_ tool: String, _ args: [String]) async {
        lock.withLock { recordedTools.append(tool) }
    }

    func capture(_ tool: String, _ args: [String]) async -> String? { nil }

    @discardableResult
    func runPrivileged(_ tool: String, _ args: [String]) async -> Bool {
        lock.withLock { recordedTools.append(tool) }
        return false
    }
}

@Suite("Sleepy Mode lock")
struct SleepyPowerControlsLockTests {
    /// Regression for https://github.com/manaflow-ai/cmux/issues/9730: macOS 26
    /// removed `User.menu` (and its `CGSession` binary) from the Menu Extras
    /// directory, so a lock implemented by shelling out to that path silently
    /// does nothing. The lock must not depend on that OS-internal binary.
    @MainActor
    @Test func lockMacDoesNotShellOutToRemovedCGSessionBinary() async throws {
        let runner = RecordingSleepyRunner()
        let defaults = try #require(UserDefaults(suiteName: "SleepyPowerControlsLockTests-\(UUID().uuidString)"))
        let controls = SleepyPowerControls(runner: runner, defaults: defaults)

        await controls.lockMacNow()

        #expect(!runner.ranTools.contains { $0.contains("/Menu Extras/User.menu/") })
    }

    /// The lock is an in-process system effect behind the runner seam: it must
    /// report the runner's result and never launch a subprocess.
    @MainActor
    @Test func lockMacEngagesTheRunnersInProcessLockWithoutSubprocesses() async throws {
        let runner = LockCapableRecordingRunner()
        let defaults = try #require(UserDefaults(suiteName: "SleepyPowerControlsLockTests-\(UUID().uuidString)"))
        let controls = SleepyPowerControls(runner: runner, defaults: defaults)

        let locked = await controls.lockMacNow()

        #expect(locked)
        #expect(runner.lockScreenCalls == 1)
        #expect(runner.ranTools.isEmpty)
    }

    /// A runner without a lock mechanism (the protocol default) reports
    /// failure instead of pretending the Mac locked.
    @MainActor
    @Test func lockMacReportsFailureWhenNoLockMechanismIsAvailable() async throws {
        let runner = RecordingSleepyRunner()
        let defaults = try #require(UserDefaults(suiteName: "SleepyPowerControlsLockTests-\(UUID().uuidString)"))
        let controls = SleepyPowerControls(runner: runner, defaults: defaults)

        let locked = await controls.lockMacNow()

        #expect(!locked)
    }

    /// Canary for the OS surface itself: `SACLockScreenImmediate` must resolve
    /// on the macOS this suite runs on. If a future macOS drops it the way
    /// macOS 26 dropped `CGSession`, this goes red instead of the Lock Mac
    /// button silently doing nothing again. Resolving the symbol does not
    /// invoke it, so this cannot lock the host.
    @Test func loginFrameworkLockResolvesOnThisMacOS() {
        #expect(LoginFrameworkScreenLock.isAvailable)
    }
}

/// Recording runner whose in-process lock succeeds, without touching the host.
private final class LockCapableRecordingRunner: SleepyCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTools: [String] = []
    private var recordedLockScreenCalls = 0

    var ranTools: [String] {
        lock.withLock { recordedTools }
    }

    var lockScreenCalls: Int {
        lock.withLock { recordedLockScreenCalls }
    }

    func run(_ tool: String, _ args: [String]) async {
        lock.withLock { recordedTools.append(tool) }
    }

    func capture(_ tool: String, _ args: [String]) async -> String? { nil }

    @discardableResult
    func runPrivileged(_ tool: String, _ args: [String]) async -> Bool {
        lock.withLock { recordedTools.append(tool) }
        return false
    }

    @discardableResult
    func lockScreen() async -> Bool {
        lock.withLock { recordedLockScreenCalls += 1 }
        return true
    }
}
