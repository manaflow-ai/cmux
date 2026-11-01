import Foundation
import Testing

private typealias Fixture = DifficultyHookFixture
private typealias Probe = DifficultyHookFixture.Probe

/// CLI-process tests for the automatic task-difficulty pass that runs next to
/// auto-naming when `cmux hooks claude auto-name` fires at turn end: its gates,
/// the call, the throttle and damping. `CLIDifficultyAssessmentTurnTests` covers
/// which prompt and reply it rates.
@Suite(.serialized)
struct CLIDifficultyAssessmentHookTests {
    // MARK: - Gates

    @Test func skipsWhenProbeSaysDisabled() throws {
        let run = try Fixture(probe: Probe(enabled: false), answer: "Hard.")
        defer { run.cleanup() }
        try run.stop()
        #expect(run.sentMethods().contains("session_priority.set"), "the probe must still be sent")
        #expect(run.priorityParams().isEmpty)
        #expect(run.classifierEfforts().isEmpty)
    }

    @Test func skipsWhenOverridePresent() throws {
        let run = try Fixture(probe: Probe(overridePresent: true), answer: "Hard.")
        defer { run.cleanup() }
        try run.stop()
        #expect(run.sentMethods().contains("session_priority.set"), "the probe must still be sent")
        #expect(run.priorityParams().isEmpty)
        #expect(run.classifierEfforts().isEmpty)
    }

    @Test func skipsWhenMarkedManual() throws {
        let run = try Fixture(probe: Probe(manual: true), answer: "Hard.")
        defer { run.cleanup() }
        try run.stop()
        #expect(run.sentMethods().contains("session_priority.set"), "the probe must still be sent")
        #expect(run.priorityParams().isEmpty)
        #expect(run.classifierEfforts().isEmpty, "a manual workspace must cost no rating call")
    }

    /// `--effort`, a user `/effort` or a launch variable leaves the workspace alone without the
    /// flag; the probe reports it as not adjustable and the pass makes no call.
    @Test func skipsWhenNotAdjustable() throws {
        let run = try Fixture(probe: Probe(adjustable: false), answer: "Hard.")
        defer { run.cleanup() }
        try run.stop()
        #expect(run.sentMethods().contains("session_priority.set"), "the probe must still be sent")
        #expect(run.priorityParams().isEmpty)
        #expect(run.classifierEfforts().isEmpty, "a workspace cmux leaves alone must cost no rating call")
    }

    @Test func assessesWhenTheAppDoesNotReportAdjustable() throws {
        let run = try Fixture(probe: Probe(adjustable: nil), answer: "Hard.")
        defer { run.cleanup() }
        try run.stop()
        #expect(run.priorityParams().first?["difficulty"] as? String == "hard")
    }

    // MARK: - The call and what it sends

    @Test func sendsAutoDifficultyOnAParsableAnswer() throws {
        let run = try Fixture(probe: Probe(), answer: "Hard.")
        defer { run.cleanup() }
        try run.stop()
        let params = run.priorityParams()
        #expect(params.count == 1)
        #expect(params.first?["difficulty"] as? String == "hard")
        #expect(params.first?["source"] as? String == "auto")
        #expect(params.first?["workspace_id"] as? String == Fixture.workspaceId)
        // The transcript is long enough for auto-naming to summarize, so this fails if the
        // difficulty pass stopped auto-naming from reaching its title.
        #expect(
            run.autoTitles() == ["Sync engine redesign"],
            "auto-naming must still have named the workspace; saw \(run.sentMethods())"
        )
    }

    @Test func doesNotSendOnAnUnparsableAnswer() throws {
        let run = try Fixture(probe: Probe(), answer: "This looks like a fairly hard task overall.")
        defer { run.cleanup() }
        try run.stop()
        #expect(run.sentMethods().contains("session_priority.set"), "the probe must still be sent")
        #expect(run.priorityParams().isEmpty)
    }

    /// The pane's Claude may run at `xhigh` or `max`; the hook inherits that variable, and the
    /// classification call must not.
    @Test func classifierRunsAtLowEffort() throws {
        let run = try Fixture(probe: Probe(), answer: "Hard.", paneEffort: "xhigh")
        defer { run.cleanup() }
        try run.stop()
        #expect(run.classifierEfforts() == ["low"])
    }

    // MARK: - Throttle across Claude restarts

    @Test func secondStopWithinThreeMinutesMakesNoSecondCall() throws {
        let run = try Fixture(probe: Probe(), answer: "Hard.")
        defer { run.cleanup() }
        try run.stop()
        try run.stop()
        #expect(run.classifierEfforts().count == 1)
    }

    /// A restart cmux makes for the new effort ends the Claude process: `SessionEnd` removes the
    /// session's hook record and the resumed Claude starts a fresh one. The throttle must hold.
    @Test func throttleSurvivesSessionEnd() throws {
        let run = try Fixture(probe: Probe(), answer: "Hard.")
        defer { run.cleanup() }
        try run.stop()
        try run.endSessionAndResume()
        try run.stop()
        #expect(run.classifierEfforts().count == 1, "the resumed session must not be rated again within 3 minutes")
    }

    // MARK: - Damping

    @Test func easierVerdictWaitsForASecondAgreeingOne() throws {
        let run = try Fixture(probe: Probe(difficultyAuto: "hard"), answer: "easy")
        defer { run.cleanup() }
        try run.stop()
        #expect(run.classifierEfforts().count == 1)
        #expect(run.priorityParams().isEmpty, "one easier verdict must not lower the difficulty")
    }

    @Test func secondAgreeingEasierVerdictIsSent() throws {
        let run = try Fixture(probe: Probe(difficultyAuto: "hard"), answer: "easy")
        defer { run.cleanup() }
        try run.seedAssessment(lastVerdict: "easy", assessedSecondsAgo: 600)
        try run.stop()
        #expect(run.priorityParams().first?["difficulty"] as? String == "easy")
    }

    @Test func verdictEqualToTheCurrentOneIsNotSentAgain() throws {
        let run = try Fixture(probe: Probe(difficultyAuto: "hard"), answer: "hard")
        defer { run.cleanup() }
        try run.stop()
        #expect(run.classifierEfforts().count == 1)
        #expect(run.priorityParams().isEmpty)
    }

    @Test func harderVerdictIsSentAtOnce() throws {
        let run = try Fixture(probe: Probe(difficultyAuto: "easy"), answer: "normal")
        defer { run.cleanup() }
        try run.stop()
        #expect(run.priorityParams().first?["difficulty"] as? String == "normal")
    }
}
