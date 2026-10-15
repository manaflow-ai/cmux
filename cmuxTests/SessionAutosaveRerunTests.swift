import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A tick that arrives while an autosave attempt is still scanning processes
/// runs as soon as that attempt ends. Before, it was dropped, so a change could
/// wait two or more 8 s intervals (14-20 s seen in dogfood) and a crash in that
/// window lost it.
final class SessionAutosaveRerunTests: XCTestCase {
    @MainActor
    func testTickDuringActiveAttemptRunsWhenItEnds() async throws {
        var fingerprintValue = 0
        var saves = 0
        let coordinator = SessionAutosaveCoordinator(
            isTerminatingApp: { false },
            isStartupSessionRestorePending: { false },
            currentTTYDeviceBindings: { [:] },
            fingerprint: { _, _ in
                fingerprintValue += 1
                return fingerprintValue
            },
            save: { _, _ in
                saves += 1
                return true
            },
            saveCurrentSnapshot: { true }
        )

        coordinator.run(source: "timer")
        let first = try XCTUnwrap(coordinator.activeAttemptTask)
        // A second tick while the first attempt is still running.
        coordinator.run(source: "timer")
        await first.value
        let rerun = try XCTUnwrap(coordinator.activeAttemptTask, "the dropped tick runs once the attempt ends")
        await rerun.value

        XCTAssertEqual(saves, 2)
        XCTAssertNil(coordinator.activeAttemptTask)
    }
}
