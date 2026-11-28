import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Once the replaced Claude has had its chance to exit, a switch types the resume only when
/// nothing could make the resumed session wrong: no old Claude still runs it, and the final
/// transcript re-sync reached the target account. Otherwise the user gets the command and decides.
struct ClaudeAccountSwitchManualResumeTests {
    @Test
    func aCleanFinishTypesTheResume() {
        #expect(ClaudeAccountSwitchManualResume.Reason.withholdingResume(
            stillRunningProcessIDs: [],
            transcriptResynced: true
        ) == nil)
    }

    /// The target's copy may miss the lines the old Claude wrote after the first copy, so
    /// resuming it would silently continue from an older conversation.
    @Test
    func aFailedTranscriptResyncWithholdsTheResume() {
        #expect(ClaudeAccountSwitchManualResume.Reason.withholdingResume(
            stillRunningProcessIDs: [],
            transcriptResynced: false
        ) == .transcriptResyncFailed)
    }

    /// A Claude still running is the stronger reason: the user must let it quit before resuming,
    /// whatever the transcript copy says.
    @Test
    func aStillRunningClaudeComesFirst() {
        #expect(ClaudeAccountSwitchManualResume.Reason.withholdingResume(
            stillRunningProcessIDs: [48_213],
            transcriptResynced: false
        ) == .previousClaudeStillRunning(processIDs: [48_213]))
        #expect(ClaudeAccountSwitchManualResume.Reason.withholdingResume(
            stillRunningProcessIDs: [48_213],
            transcriptResynced: true
        ) == .previousClaudeStillRunning(processIDs: [48_213]))
    }
}
