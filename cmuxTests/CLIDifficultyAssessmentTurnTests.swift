import Foundation
import Testing

private typealias Fixture = DifficultyHookFixture
private typealias Probe = DifficultyHookFixture.Probe

/// CLI-process tests for which prompt and reply the turn-end difficulty pass rates: the reply is
/// the one the `Stop` input carries, which Claude Code writes to the transcript only after the
/// async hook starts, and the user may send the next prompt while auto-naming's call runs first.
@Suite(.serialized)
struct CLIDifficultyAssessmentTurnTests {
    private static let step7 = "Redesign the sync engine, step 7"

    /// A `Stop` input without the turn's reply (a Claude Code that does not pass it): no call,
    /// even with a reply on disk, since nothing tells the hook when this turn's reply lands there
    /// (ruling R46). The skip does not start the 3 minute window, so the next turn end is rated.
    @Test func makesNoCallWhenTheStopInputCarriesNoReply() throws {
        let run = try Fixture(probe: Probe(), answer: "Hard.")
        defer { run.cleanup() }
        try run.stop(lastAssistantMessage: nil)
        #expect(run.classifierPrompts().isEmpty, "saw \(run.classifierPrompts())")
        #expect(run.priorityParams().isEmpty)

        try run.stop()
        #expect(run.classifierPrompts().count == 1)
        #expect(run.rated(user: "Redesign the sync engine, step 6", reply: Fixture.sixthReply))
    }

    /// Claude Code passes the turn's final reply to the `Stop` hook as `last_assistant_message`;
    /// it is used even before it reaches the transcript.
    @Test func usesTheReplyTheStopInputCarries() throws {
        let reply = "Planned the cut-over for step 7."
        let run = try Fixture(probe: Probe(), answer: "Hard.", transcript: Fixture.sixExchanges + [Fixture.userLine(Self.step7)])
        defer { run.cleanup() }
        try run.stop(lastAssistantMessage: reply)
        #expect(run.classifierPrompts().count == 1)
        #expect(run.rated(user: Self.step7, reply: reply), "saw \(run.classifierPrompts())")
    }

    /// An earlier turn ended with the same reply text, and this turn's reply reaches the transcript
    /// only after the hook starts (here during naming's call): the rated prompt is still this turn's.
    @Test func ratesThisTurnsPromptWhenAnEarlierReplyWasTheSame() throws {
        let prompt = "Design a multi-region Postgres failover, then reply with exactly OK."
        let run = try Fixture(probe: Probe(), answer: "Hard.", transcript: Fixture.sixExchanges + [
            Fixture.userLine("Remember the codeword TANGERINE. Reply with exactly OK."), Fixture.assistantLine("OK"),
            Fixture.userLine(prompt),
        ], duringNaming: [Fixture.assistantLine("OK")])
        defer { run.cleanup() }
        try run.stop(lastAssistantMessage: "OK")
        #expect(try String(contentsOf: run.transcript, encoding: .utf8).hasSuffix(Fixture.assistantLine("OK") + "\n"), "naming must have run")
        #expect(run.classifierPrompts().count == 1)
        #expect(run.rated(user: prompt, reply: "OK"), "saw \(run.classifierPrompts())")
    }

    /// The user sends the next prompt during auto-naming's call, before the rating reads anything:
    /// the Stop input's reply is still rated with this turn's prompt.
    @Test func keepsThisTurnsPromptWhenTheNextOneArrivesDuringNaming() throws {
        let next = Fixture.userLine("Now rename the README title.")
        let run = try Fixture(probe: Probe(), answer: "Hard.", transcript: Fixture.sixExchanges + [Fixture.userLine(Self.step7)], duringNaming: [next])
        defer { run.cleanup() }
        try run.stop(lastAssistantMessage: "Planned the cut-over for step 7.")
        #expect(try String(contentsOf: run.transcript, encoding: .utf8).hasSuffix(next + "\n"), "naming must have run")
        #expect(run.classifierPrompts().count == 1)
        #expect(run.rated(user: Self.step7), "saw \(run.classifierPrompts())")
    }

    /// The transcript was truncated or replaced during naming's call by a shorter one with another
    /// prompt: what the hook recorded at its start is gone, so nothing is rated rather than a
    /// prompt read from another file.
    @Test func skipsWhenTheTranscriptShrankSinceTheHookStarted() throws {
        let other = Fixture.userLine("Delete the build cache.")
        let run = try Fixture(probe: Probe(), answer: "Hard.", transcript: Fixture.sixExchanges + [Fixture.userLine(Self.step7)], replaceDuringNaming: [other])
        defer { run.cleanup() }
        try run.stop(lastAssistantMessage: "Planned the cut-over for step 7.")
        #expect(try String(contentsOf: run.transcript, encoding: .utf8) == other + "\n", "naming must have replaced it")
        #expect(run.classifierPrompts().isEmpty, "saw \(run.classifierPrompts())")
        #expect(run.priorityParams().isEmpty)
    }

    /// The sync `Stop` hook can hold the session store's lock at turn end. Meanwhile the reply and
    /// a queued next prompt reach the transcript; the size the hook noted before waiting on that
    /// lock still ends at this turn's prompt.
    @Test func notesTheTranscriptSizeBeforeWaitingOnTheSessionStore() throws {
        let reply = "Planned the cut-over for step 7."
        let run = try Fixture(probe: Probe(), answer: "Hard.", transcript: Fixture.sixExchanges + [Fixture.userLine(Self.step7)])
        defer { run.cleanup() }
        try run.stopWhileStoreIsLocked(lastAssistantMessage: reply) {
            try run.appendToTranscript(Fixture.assistantLine(reply))
            try run.appendToTranscript(Fixture.userLine("Now rename the README title."))
        }
        #expect(run.classifierPrompts().count == 1)
        #expect(run.rated(user: Self.step7, reply: reply), "saw \(run.classifierPrompts())")
    }

    @Test func ratesAFirstTurnFromTheStopInput() throws {
        let run = try Fixture(probe: Probe(), answer: "Hard.", transcript: [Fixture.userLine("Plan a zero-downtime migration.")])
        defer { run.cleanup() }
        try run.stop(lastAssistantMessage: "Here is the migration plan.")
        #expect(run.classifierPrompts().count == 1, "the first turn must be rated")
        #expect(run.priorityParams().first?["difficulty"] as? String == "hard")
    }
}
