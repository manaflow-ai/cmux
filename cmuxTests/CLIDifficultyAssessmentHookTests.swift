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

    /// The transcript ends with the new prompt when the hook starts; its reply lands 300 ms
    /// after the hook's probe. The rating pairs the prompt with that reply, not the previous one.
    @Test func ratesTheReplyThatLandsAfterTheHookStarts() throws {
        let reply = "Cut the sync engine over in three phases."
        let run = try Fixture(
            probe: Probe(),
            answer: "Hard.",
            transcript: Fixture.sixExchanges + [Fixture.userLine("Redesign the sync engine, step 7")],
            lateReply: reply
        )
        defer { run.cleanup() }
        try run.stop()
        let prompts = run.classifierPrompts()
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("<user_message>\nRedesign the sync engine, step 7\n</user_message>") == true)
        #expect(
            prompts.first?.contains("<assistant_message>\n\(reply)\n</assistant_message>") == true,
            "the rating must see this turn's reply; saw \(prompts)"
        )
        #expect(run.priorityParams().first?["difficulty"] as? String == "hard")
    }

    /// A new conversation's first turn: only the prompt is on disk when the hook starts.
    @Test func ratesTheFirstTurnOfAConversation() throws {
        let reply = "Here is the migration plan."
        let run = try Fixture(
            probe: Probe(),
            answer: "Hard.",
            transcript: [Fixture.userLine("Plan a zero-downtime migration to async/await.")],
            lateReply: reply
        )
        defer { run.cleanup() }
        try run.stop()
        let prompts = run.classifierPrompts()
        #expect(prompts.count == 1, "the first turn must be rated")
        #expect(prompts.first?.contains("<assistant_message>\n\(reply)\n</assistant_message>") == true)
        #expect(run.priorityParams().first?["difficulty"] as? String == "hard")
    }

    /// No reply within the wait: no call, rather than pairing the prompt with an older reply.
    /// The skip does not start the 3 minute window, so the next turn end is rated.
    @Test func makesNoCallWhenNoReplyArrives() throws {
        let run = try Fixture(
            probe: Probe(),
            answer: "Hard.",
            transcript: Fixture.sixExchanges + [Fixture.userLine("Redesign the sync engine, step 7")]
        )
        defer { run.cleanup() }
        try run.stop()
        #expect(run.classifierPrompts().isEmpty, "a prompt must never be rated with the previous turn's reply")
        #expect(run.priorityParams().isEmpty)

        try run.appendToTranscript(Fixture.assistantLine("Step 7 is mapped."))
        try run.stop()
        #expect(run.classifierPrompts().count == 1)
        #expect(run.classifierPrompts().first?.contains("<assistant_message>\nStep 7 is mapped.\n</assistant_message>") == true)
    }

    /// Claude Code passes the turn's final reply to the `Stop` hook as `last_assistant_message`;
    /// it is used even before it reaches the transcript.
    @Test func usesTheReplyTheStopInputCarries() throws {
        let reply = "Planned the cut-over for step 7."
        let run = try Fixture(
            probe: Probe(),
            answer: "Hard.",
            transcript: Fixture.sixExchanges + [Fixture.userLine("Redesign the sync engine, step 7")]
        )
        defer { run.cleanup() }
        try run.stop(lastAssistantMessage: reply)
        let prompts = run.classifierPrompts()
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("<user_message>\nRedesign the sync engine, step 7\n</user_message>") == true)
        #expect(prompts.first?.contains("<assistant_message>\n\(reply)\n</assistant_message>") == true, "saw \(prompts)")
    }

    @Test func ratesAFirstTurnFromTheStopInput() throws {
        let run = try Fixture(
            probe: Probe(),
            answer: "Hard.",
            transcript: [Fixture.userLine("Plan a zero-downtime migration to async/await.")]
        )
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
    init(
        probe: Tests.Probe,
        answer: String,
        paneEffort: String? = nil,
        transcript lines: [String] = Fixture.sixExchanges,
        lateReply: String? = nil
    ) throws {
        context = try Harness.makeContext(name: "difficulty-hook")
        self.paneEffort = paneEffort
        try Self.writeFreshSessionRecord(context: context)

        transcript = context.root.appendingPathComponent("transcript.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

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

    func appendToTranscript(_ line: String) throws {
        try Self.append(line, to: transcript)
    }

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
