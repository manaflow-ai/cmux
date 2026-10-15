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

    /// Under load an attempt can outlast several ticks. Each is counted (and
    /// logged in DEBUG as session.save.deferred), and they collapse into one
    /// follow-up save as soon as the slow attempt ends, not a pile-up and not a
    /// silent gap.
    @MainActor
    func testTicksDuringASlowSaveCollapseIntoOneFollowUp() async throws {
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
                // A slow save: the main actor is busy writing.
                Thread.sleep(forTimeInterval: 0.05)
                saves += 1
                return true
            },
            saveCurrentSnapshot: { true }
        )

        coordinator.run(source: "timer")
        let first = try XCTUnwrap(coordinator.activeAttemptTask)
        for _ in 0..<3 { coordinator.run(source: "timer") }
        XCTAssertEqual(coordinator.deferredTickCount, 3)
        await first.value
        let followUp = try XCTUnwrap(coordinator.activeAttemptTask)
        await followUp.value

        XCTAssertEqual(saves, 2, "one save for the slow attempt, one follow-up for the deferred ticks")
        XCTAssertNil(coordinator.activeAttemptTask)
    }
}
