import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Truth table for `SleepyModeController.shouldKeepAwake(...)` and the
/// `anyAgentWorking(in:)` busy classification. These pin the two-owner
/// power-assertion contract: the Sleepy Mode screensaver and Amphetamine Mode
/// are independent hold-reasons, and neither may release an assertion the other
/// still needs (issue #7537).
@Suite
struct SleepyModeKeepAwakeReconcileTests {
    // MARK: shouldKeepAwake truth table

    @Test func screensaverActiveAlwaysKeepsAwake() {
        // Screensaver holds even with the setting off and no agent working.
        #expect(SleepyModeController.shouldKeepAwake(
            screensaverActive: true, keepAwakeSetting: false, anyAgentWorking: false))
    }

    @Test func amphetamineKeepsAwakeWhenSettingOnAndAgentWorking() {
        #expect(SleepyModeController.shouldKeepAwake(
            screensaverActive: false, keepAwakeSetting: true, anyAgentWorking: true))
    }

    @Test func idleAgentDoesNotKeepAwake() {
        #expect(!SleepyModeController.shouldKeepAwake(
            screensaverActive: false, keepAwakeSetting: true, anyAgentWorking: false))
    }

    @Test func settingOffDoesNotKeepAwakeEvenIfAgentWorking() {
        #expect(!SleepyModeController.shouldKeepAwake(
            screensaverActive: false, keepAwakeSetting: false, anyAgentWorking: true))
    }

    @Test func nothingActiveReleases() {
        #expect(!SleepyModeController.shouldKeepAwake(
            screensaverActive: false, keepAwakeSetting: false, anyAgentWorking: false))
    }

    /// Regression guard for the clobber bug: an Amphetamine hold must survive the
    /// screensaver closing while an agent is still working.
    @Test func amphetamineHoldSurvivesScreensaverClose() {
        // Screensaver open on top of an active amphetamine hold.
        #expect(SleepyModeController.shouldKeepAwake(
            screensaverActive: true, keepAwakeSetting: true, anyAgentWorking: true))
        // Screensaver closes; agent still working -> STILL awake.
        #expect(SleepyModeController.shouldKeepAwake(
            screensaverActive: false, keepAwakeSetting: true, anyAgentWorking: true))
    }

    // MARK: anyAgentWorking(in:)

    @Test func anyAgentWorkingDetectsCommandRunning() {
        #expect(SleepyModeController.anyAgentWorking(in: [
            [.promptIdle],
            [.commandRunning, .promptIdle],
        ]))
    }

    @Test func anyAgentWorkingFalseWhenAllIdleOrUnknown() {
        #expect(!SleepyModeController.anyAgentWorking(in: [
            [.promptIdle, .unknown],
            [],
        ]))
    }

    @Test func anyAgentWorkingFalseWhenNoWorkspaces() {
        #expect(!SleepyModeController.anyAgentWorking(in: []))
    }
}
