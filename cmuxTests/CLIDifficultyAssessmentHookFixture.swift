import Foundation
import Testing

/// One difficulty-hook test's mock cmux, fake `claude`, transcript and state files, for
/// `CLIDifficultyAssessmentHookTests` and `CLIDifficultyAssessmentTurnTests`.
struct DifficultyHookFixture {
    typealias Harness = ClaudeHookLiveDeliveryHarness

    static let workspaceId = "11111111-1111-1111-1111-111111111111"
    static let surfaceId = "22222222-2222-2222-2222-222222222222"
    static let sessionId = "difficulty-hook-session"

    /// What the app's `session_priority.set` probe answers.
    struct Probe {
        var enabled = true
        var manual = false
        var overridePresent = false
        /// `nil` leaves the key out, as an app that predates it does.
        var adjustable: Bool? = true
        var difficultyAuto: String?
    }

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
    ///   prompt, as the user sends the next prompt during that call. `replaceDuringNaming`
    ///   instead replaces the whole transcript with these lines, as a truncated or rotated file.
    init(
        probe: Probe,
        answer: String,
        paneEffort: String? = nil,
        transcript lines: [String] = DifficultyHookFixture.sixExchanges,
        lateReply: String? = nil,
        duringNaming: [String] = [],
        replaceDuringNaming: [String] = []
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
        let replacement = context.root.appendingPathComponent("replace-during-naming.jsonl")
        if !replaceDuringNaming.isEmpty {
            try (replaceDuringNaming.joined(separator: "\n") + "\n").write(to: replacement, atomically: true, encoding: .utf8)
        }

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
            [ -f '\(replacement.path)' ] && cp '\(replacement.path)' '\(transcript.path)'
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
        let (environment, input) = hookInvocation(lastAssistantMessage: lastAssistantMessage)
        let result = Harness.runHookProcess(
            context: context, arguments: ["hooks", "claude", "auto-name"], environment: environment, standardInput: input
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
    }

    /// Runs the turn-end hook while the hook session store's lock is held, as the sync `Stop`
    /// hook can hold it at turn end. `whileLocked` runs once the hook has had 2 s to start and
    /// read its input; then the lock is released and the hook finishes.
    func stopWhileStoreIsLocked(lastAssistantMessage: String, whileLocked: () throws -> Void) throws {
        let lockFD = open(context.storeURL.path + ".lock", O_RDWR | O_CREAT, 0o600)
        try #require(lockFD >= 0)
        defer { close(lockFD) }
        try #require(flock(lockFD, LOCK_EX) == 0)
        let (environment, input) = hookInvocation(lastAssistantMessage: lastAssistantMessage)
        let context = context
        let box = ResultBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.result = Harness.runHookProcess(
                context: context, arguments: ["hooks", "claude", "auto-name"], environment: environment, standardInput: input
            )
            finished.signal()
        }
        Thread.sleep(forTimeInterval: 2)
        let appended = Result { try whileLocked() }
        flock(lockFD, LOCK_UN)
        finished.wait()
        try appended.get()
        let result = try #require(box.result)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
    }

    private final class ResultBox: @unchecked Sendable {
        var result: Harness.ProcessRunResult?
    }

    private func hookInvocation(lastAssistantMessage: String?) -> (environment: [String: String], input: String) {
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.workspaceId
        environment["CMUX_SURFACE_ID"] = Self.surfaceId
        environment["CMUX_CLAUDE_PID"] = "43301"
        environment["CMUX_CUSTOM_CLAUDE_PATH"] = fakeClaude.path
        if let paneEffort { environment["CLAUDE_CODE_EFFORT_LEVEL"] = paneEffort }
        var input: [String: Any] = [
            "session_id": Self.sessionId,
            "hook_event_name": "Stop",
            "cwd": context.root.path,
            "transcript_path": transcript.path,
        ]
        if let lastAssistantMessage { input["last_assistant_message"] = lastAssistantMessage }
        return (environment, Self.jsonLine(input))
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

    /// Whether the first rating call's prompt held `user` as the prompt and `reply` as the reply.
    func rated(user: String? = nil, reply: String? = nil) -> Bool {
        guard let prompt = classifierPrompts().first else { return false }
        let blocks = [user.map { "<user_message>\n\($0)\n</user_message>" }, reply.map { "<assistant_message>\n\($0)\n</assistant_message>" }]
        return blocks.compactMap { $0 }.allSatisfy { prompt.contains($0) }
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
            "sessions": [Self.sessionId: ["lastAssessedAt": at, "lastVerdict": lastVerdict, "updatedAt": at]],
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
            sessionId: Self.sessionId,
            workspaceId: Self.workspaceId,
            surfaceId: Self.surfaceId,
            cwd: context.root.path
        )
    }

    private static func respond(to line: String, probe: Probe) -> String {
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
                "workspace_id": Self.workspaceId,
                "manual": probe.manual,
                "override_present": probe.overridePresent,
                "difficulty_auto": probe.difficultyAuto.map { $0 as Any } ?? NSNull(),
            ]
            if let adjustable = probe.adjustable { result["adjustable"] = adjustable }
            return Harness.v2Response(id: id, ok: true, result: result)
        case "surface.list":
            return Harness.v2Response(id: id, ok: true, result: [
                "surfaces": [["id": Self.surfaceId, "ref": "surface:1", "focused": true]],
            ])
        default:
            return Harness.v2Response(id: id, ok: false, error: ["code": "not_found", "message": method])
        }
    }
}
