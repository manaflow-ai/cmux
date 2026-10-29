import Foundation
import Testing

/// CLI-process tests for the automatic task-difficulty pass that runs next to
/// auto-naming when `cmux hooks claude auto-name` fires at turn end.
@Suite(.serialized)
struct CLIDifficultyAssessmentHookTests {
    fileprivate static let workspaceId = "11111111-1111-1111-1111-111111111111"
    fileprivate static let surfaceId = "22222222-2222-2222-2222-222222222222"
    fileprivate static let sessionId = "difficulty-hook-session"

    fileprivate struct Probe {
        var enabled = true
        var manual = false
        var overridePresent = false
        /// `nil` leaves the key out, as an app that predates it does.
        var adjustable: Bool? = true
        var difficultyAuto: String?
    }

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
        #expect(params.first?["workspace_id"] as? String == Self.workspaceId)
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

    // MARK: - This turn's reply (Claude Code writes it after the async Stop hook starts)

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

    /// The transcript was truncated or replaced during naming's call: what the hook recorded at its
    /// start is gone, so nothing is rated rather than a prompt read from another file.
    @Test func skipsWhenTheTranscriptShrankSinceTheHookStarted() throws {
        let run = try Fixture(probe: Probe(), answer: "Hard.", transcript: Fixture.sixExchanges + [Fixture.userLine(Self.step7)], truncateDuringNaming: true)
        defer { run.cleanup() }
        try run.stop(lastAssistantMessage: "Planned the cut-over for step 7.")
        #expect(try String(contentsOf: run.transcript, encoding: .utf8).isEmpty, "naming must have run")
        #expect(run.classifierPrompts().isEmpty)
        #expect(run.priorityParams().isEmpty)
    }

    @Test func ratesAFirstTurnFromTheStopInput() throws {
        let run = try Fixture(probe: Probe(), answer: "Hard.", transcript: [Fixture.userLine("Plan a zero-downtime migration.")])
        defer { run.cleanup() }
        try run.stop(lastAssistantMessage: "Here is the migration plan.")
        #expect(run.classifierPrompts().count == 1, "the first turn must be rated")
        #expect(run.priorityParams().first?["difficulty"] as? String == "hard")
    }
}

/// One test's mock cmux, fake `claude`, transcript and state files.
private struct Fixture {
    fileprivate typealias Harness = ClaudeHookLiveDeliveryHarness
    fileprivate typealias Tests = CLIDifficultyAssessmentHookTests

    let context: Harness.Context
    let transcript: URL
    let fakeClaude: URL
    let effortLog: URL
    let promptLog: URL
    let paneEffort: String?

    /// Six exchanges: past auto-naming's short-transcript skip; the last one is rated.
    static let sixExchanges: [String] = (1...6).flatMap { index in
        [userLine("Redesign the sync engine, step \(index)"), assistantLine("Mapping the dependencies for step \(index).")]
    }

    static func userLine(_ text: String) -> String {
        jsonLine(["type": "user", "message": ["role": "user", "content": text]])
    }

    static func assistantLine(_ text: String) -> String {
        jsonLine(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    private static func jsonLine(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// - Parameter lateReply: an assistant line appended to the transcript 300 ms after the
    ///   hook's difficulty probe reaches cmux, as Claude Code writes the turn's reply after the
    ///   async `Stop` hook has started.
    /// - Parameter duringNaming: lines the fake `claude` appends while it answers auto-naming's
    ///   prompt, as the user sends the next prompt during that call. `truncateDuringNaming`
    ///   empties the transcript then instead.
    init(
        probe: Tests.Probe,
        answer: String,
        paneEffort: String? = nil,
        transcript lines: [String] = Fixture.sixExchanges,
        lateReply: String? = nil,
        duringNaming: [String] = [],
        truncateDuringNaming: Bool = false
    ) throws {
        context = try Harness.makeContext(name: "difficulty-hook")
        self.paneEffort = paneEffort
        try Self.writeFreshSessionRecord(context: context)

        transcript = context.root.appendingPathComponent("transcript.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let pending = context.root.appendingPathComponent("during-naming.jsonl")
        if !duringNaming.isEmpty {
            try (duringNaming.joined(separator: "\n") + "\n").write(to: pending, atomically: true, encoding: .utf8)
        }
        let truncate = context.root.appendingPathComponent("truncate-during-naming")
        if truncateDuringNaming { try Data().write(to: truncate) }

        // Answers the rating prompt with `answer`, logging the prompt and the effort it ran at;
        // answers auto-naming's prompt with a title.
        effortLog = context.root.appendingPathComponent("classifier-efforts.log")
        promptLog = context.root.appendingPathComponent("classifier-prompts.log")
        fakeClaude = context.root.appendingPathComponent("fake-claude")
        let script = """
        #!/bin/sh
        input=$(cat)
        case "$input" in
          *"Classify how demanding"*)
            printf '%s\\n' "${CLAUDE_CODE_EFFORT_LEVEL:-unset}" >> '\(effortLog.path)'
            printf '%s\\n%s\\n' "$input" '\(Self.promptSeparator)' >> '\(promptLog.path)'
            printf '%s\\n' '\(answer)'
            ;;
          *)
            if [ -f '\(pending.path)' ]; then
              cat '\(pending.path)' >> '\(transcript.path)' && mv '\(pending.path)' '\(pending.path).done'
            fi
            [ -f '\(truncate.path)' ] && : > '\(transcript.path)'
            printf '%s\\n' 'Sync engine redesign'
            ;;
        esac
        """
        try script.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let transcriptURL = transcript
        let lateLine = lateReply.map(Self.assistantLine)
        _ = Harness.startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            if let lateLine, Self.isDifficultyProbe(line) {
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) {
                    try? Self.append(lateLine, to: transcriptURL)
                }
            }
            return Self.respond(to: line, probe: probe)
        }
    }

    private static let promptSeparator = "----- end of rating prompt -----"

    func cleanup() { context.cleanup() }

    /// Runs the turn-end hook once. `lastAssistantMessage` is the turn's reply as Claude Code
    /// passes it in the `Stop` input; `nil` leaves the key out.
    func stop(lastAssistantMessage: String? = nil) throws {
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Tests.workspaceId
        environment["CMUX_SURFACE_ID"] = Tests.surfaceId
        environment["CMUX_CLAUDE_PID"] = "43301"
        environment["CMUX_CUSTOM_CLAUDE_PATH"] = fakeClaude.path
        if let paneEffort { environment["CLAUDE_CODE_EFFORT_LEVEL"] = paneEffort }
        var input: [String: Any] = [
            "session_id": Tests.sessionId,
            "hook_event_name": "Stop",
            "cwd": context.root.path,
            "transcript_path": transcript.path,
        ]
        if let lastAssistantMessage { input["last_assistant_message"] = lastAssistantMessage }
        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "auto-name"],
            environment: environment,
            standardInput: Self.jsonLine(input)
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
    }

    func appendToTranscript(_ line: String) throws { try Self.append(line, to: transcript) }

    private static func append(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private static func isDifficultyProbe(_ line: String) -> Bool {
        guard let payload = Harness.jsonObject(line), payload["method"] as? String == "session_priority.set" else {
            return false
        }
        return (payload["params"] as? [String: Any])?["probe"] as? Bool == true
    }

    /// The prompt of each rating call, one per call.
    /// Whether the first rating call's prompt held `user` as the prompt and `reply` as the reply.
    func rated(user: String? = nil, reply: String? = nil) -> Bool {
        guard let prompt = classifierPrompts().first else { return false }
        let blocks = [user.map { "<user_message>\n\($0)\n</user_message>" }, reply.map { "<assistant_message>\n\($0)\n</assistant_message>" }]
        return blocks.compactMap { $0 }.allSatisfy { prompt.contains($0) }
    }

    func classifierPrompts() -> [String] {
        guard let text = try? String(contentsOf: promptLog, encoding: .utf8) else { return [] }
        return text.components(separatedBy: Self.promptSeparator + "\n").filter { !$0.isEmpty }
    }

    /// What a Claude restart leaves in the hook session store: `SessionEnd` removed the
    /// session's record, and the resumed Claude's `SessionStart` wrote a fresh one.
    func endSessionAndResume() throws {
        let empty: [String: Any] = ["version": 1, "sessions": [String: Any]()]
        try JSONSerialization.data(withJSONObject: empty).write(to: context.storeURL)
        try Self.writeFreshSessionRecord(context: context)
    }

    /// Records an earlier assessment of the session in the difficulty store.
    func seedAssessment(lastVerdict: String, assessedSecondsAgo: TimeInterval) throws {
        let at = Date().timeIntervalSince1970 - assessedSecondsAgo
        let store: [String: Any] = [
            "version": 1,
            "sessions": [Tests.sessionId: ["lastAssessedAt": at, "lastVerdict": lastVerdict, "updatedAt": at]],
        ]
        try JSONSerialization.data(withJSONObject: store).write(
            to: context.root.appendingPathComponent("claude-difficulty-assessments.json")
        )
    }

    /// The effort each rating call ran at, one per call.
    func classifierEfforts() -> [String] {
        guard let text = try? String(contentsOf: effortLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// `session_priority.set` calls other than the probe.
    func priorityParams() -> [[String: Any]] {
        params(of: "session_priority.set").filter { $0["probe"] == nil }
    }

    /// Titles auto-naming applied with `workspace.set_auto_title`.
    func autoTitles() -> [String] {
        params(of: "workspace.set_auto_title").compactMap { $0["title"] as? String }
    }

    func sentMethods() -> [String] {
        context.state.snapshot().compactMap { Harness.jsonObject($0)?["method"] as? String }
    }

    private func params(of method: String) -> [[String: Any]] {
        context.state.snapshot().compactMap { line -> [String: Any]? in
            guard let payload = Harness.jsonObject(line),
                  payload["method"] as? String == method else { return nil }
            return payload["params"] as? [String: Any]
        }
    }

    private static func writeFreshSessionRecord(context: Harness.Context) throws {
        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: Tests.sessionId,
            workspaceId: Tests.workspaceId,
            surfaceId: Tests.surfaceId,
            cwd: context.root.path
        )
    }

    private static func respond(to line: String, probe: Tests.Probe) -> String {
        guard let payload = Harness.jsonObject(line),
              let id = payload["id"] as? String,
              let method = payload["method"] as? String else { return "OK" }
        switch method {
        case "workspace.set_auto_title":
            return Harness.v2Response(id: id, ok: true, result: ["enabled": true, "workspace_applied": true])
        case "session_priority.set":
            let params = payload["params"] as? [String: Any] ?? [:]
            guard params["probe"] as? Bool == true else {
                return Harness.v2Response(id: id, ok: true, result: [:])
            }
            var result: [String: Any] = [
                "enabled": probe.enabled,
                "workspace_id": Tests.workspaceId,
                "manual": probe.manual,
                "override_present": probe.overridePresent,
                "difficulty_auto": probe.difficultyAuto.map { $0 as Any } ?? NSNull(),
            ]
            if let adjustable = probe.adjustable { result["adjustable"] = adjustable }
            return Harness.v2Response(id: id, ok: true, result: result)
        case "surface.list":
            return Harness.v2Response(id: id, ok: true, result: [
                "surfaces": [["id": Tests.surfaceId, "ref": "surface:1", "focused": true]],
            ])
        default:
            return Harness.v2Response(id: id, ok: false, error: ["code": "not_found", "message": method])
        }
    }
}
