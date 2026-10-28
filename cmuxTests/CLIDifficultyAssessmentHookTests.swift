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
}

/// One test's mock cmux, fake `claude`, transcript and state files.
private struct Fixture {
    fileprivate typealias Harness = ClaudeHookLiveDeliveryHarness
    fileprivate typealias Tests = CLIDifficultyAssessmentHookTests

    let context: Harness.Context
    let transcript: URL
    let fakeClaude: URL
    let effortLog: URL
    let paneEffort: String?

    init(probe: Tests.Probe, answer: String, paneEffort: String? = nil) throws {
        context = try Harness.makeContext(name: "difficulty-hook")
        self.paneEffort = paneEffort
        try Self.writeFreshSessionRecord(context: context)

        // Six exchanges: past auto-naming's short-transcript skip; the last one is rated.
        transcript = context.root.appendingPathComponent("transcript.jsonl")
        var lines: [String] = []
        for index in 1...6 {
            lines.append(#"{"type":"user","message":{"role":"user","content":"Redesign the sync engine, step \#(index)"}}"#)
            lines.append(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Mapping the dependencies for step \#(index)."}]}}"#)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        // Answers the rating prompt with `answer` and logs the effort it ran at; answers
        // auto-naming's prompt with a title.
        effortLog = context.root.appendingPathComponent("classifier-efforts.log")
        fakeClaude = context.root.appendingPathComponent("fake-claude")
        let script = """
        #!/bin/sh
        input=$(cat)
        case "$input" in
          *"Classify how demanding"*)
            printf '%s\\n' "${CLAUDE_CODE_EFFORT_LEVEL:-unset}" >> '\(effortLog.path)'
            printf '%s\\n' '\(answer)'
            ;;
          *)
            printf '%s\\n' 'Sync engine redesign'
            ;;
        esac
        """
        try script.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        _ = Harness.startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            Self.respond(to: line, probe: probe)
        }
    }

    func cleanup() { context.cleanup() }

    /// Runs the turn-end hook once.
    func stop() throws {
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Tests.workspaceId
        environment["CMUX_SURFACE_ID"] = Tests.surfaceId
        environment["CMUX_CLAUDE_PID"] = "43301"
        environment["CMUX_CUSTOM_CLAUDE_PATH"] = fakeClaude.path
        if let paneEffort { environment["CLAUDE_CODE_EFFORT_LEVEL"] = paneEffort }
        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "auto-name"],
            environment: environment,
            standardInput: #"{"session_id":"\#(Tests.sessionId)","hook_event_name":"Stop","cwd":"\#(context.root.path)","transcript_path":"\#(transcript.path)"}"#
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
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
