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
}
