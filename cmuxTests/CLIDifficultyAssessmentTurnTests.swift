import Foundation
import Testing

private typealias Fixture = DifficultyHookFixture
private typealias Probe = DifficultyHookFixture.Probe

/// CLI-process tests for which prompt and reply the turn-end difficulty pass rates: Claude Code
/// writes the turn's reply after the async `Stop` hook starts, and the user may send the next
/// prompt while auto-naming's call runs first.
@Suite(.serialized)
struct CLIDifficultyAssessmentTurnTests {
    private static let step7 = "Redesign the sync engine, step 7"

    /// The transcript ends with the new prompt when the hook starts; its reply lands 300 ms
    /// after the hook's probe. The rating pairs the prompt with that reply, not the previous one.
    @Test func ratesTheReplyThatLandsAfterTheHookStarts() throws {
        let reply = "Cut the sync engine over in three phases."
        let run = try Fixture(probe: Probe(), answer: "Hard.", transcript: Fixture.sixExchanges + [Fixture.userLine(Self.step7)], lateReply: reply)
        defer { run.cleanup() }
        try run.stop()
        #expect(run.classifierPrompts().count == 1)
        #expect(run.rated(user: Self.step7, reply: reply), "the rating must see this turn's reply; saw \(run.classifierPrompts())")
        #expect(run.priorityParams().first?["difficulty"] as? String == "hard")
    }

    /// A new conversation's first turn: only the prompt is on disk when the hook starts.
    @Test func ratesTheFirstTurnOfAConversation() throws {
        let reply = "Here is the migration plan."
        let run = try Fixture(probe: Probe(), answer: "Hard.", transcript: [Fixture.userLine("Plan a zero-downtime migration.")], lateReply: reply)
        defer { run.cleanup() }
        try run.stop()
        #expect(run.classifierPrompts().count == 1, "the first turn must be rated")
        #expect(run.rated(reply: reply))
        #expect(run.priorityParams().first?["difficulty"] as? String == "hard")
    }

    /// No reply within the wait: no call, rather than pairing the prompt with an older reply.
    /// The skip does not start the 3 minute window, so the next turn end is rated.
    @Test func makesNoCallWhenNoReplyArrives() throws {
        let run = try Fixture(probe: Probe(), answer: "Hard.", transcript: Fixture.sixExchanges + [Fixture.userLine(Self.step7)])
        defer { run.cleanup() }
        try run.stop()
        #expect(run.classifierPrompts().isEmpty, "a prompt must never be rated with the previous turn's reply")
        #expect(run.priorityParams().isEmpty)

        try run.appendToTranscript(Fixture.assistantLine("Step 7 is mapped."))
        try run.stop()
        #expect(run.classifierPrompts().count == 1)
        #expect(run.rated(user: Self.step7, reply: "Step 7 is mapped."))
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
    /// only after the hook starts: the rated prompt is still this turn's.
    @Test func ratesThisTurnsPromptWhenAnEarlierReplyWasTheSame() throws {
        let prompt = "Design a multi-region Postgres failover, then reply with exactly OK."
        let run = try Fixture(probe: Probe(), answer: "Hard.", transcript: [
            Fixture.userLine("Remember the codeword TANGERINE. Reply with exactly OK."), Fixture.assistantLine("OK"),
            Fixture.userLine(prompt),
        ], lateReply: "OK")
        defer { run.cleanup() }
        try run.stop(lastAssistantMessage: "OK")
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
