import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the restore gate's intentional-relaunch override: an
/// intentional relaunch forces restore even with launch arguments, but the
/// disable flag still wins.
@Suite struct CrashRecoveryRestoreGateTests {

    @Test func restoreIntendedForcesRestoreDespiteLaunchArguments() {
        // Launch args normally mean "explicit open intent" => no restore.
        #expect(!SessionRestorePolicy.shouldAttemptRestore(
            arguments: ["cmux", "/some/path"], environment: [:], restoreIntended: false
        ))
        // But an intentional relaunch forces restore.
        #expect(SessionRestorePolicy.shouldAttemptRestore(
            arguments: ["cmux", "/some/path"], environment: [:], restoreIntended: true
        ))
    }

    @Test func disableFlagWinsOverRestoreIntent() {
        #expect(!SessionRestorePolicy.shouldAttemptRestore(
            arguments: ["cmux"],
            environment: ["CMUX_DISABLE_SESSION_RESTORE": "1"],
            restoreIntended: true
        ))
    }

    @Test func normalCleanLaunchUnchanged() {
        // No args, no intent => restore (existing behavior).
        #expect(SessionRestorePolicy.shouldAttemptRestore(
            arguments: ["cmux"], environment: [:], restoreIntended: false
        ))
    }
}
