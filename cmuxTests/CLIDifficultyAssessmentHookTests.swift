import Foundation
import Testing

/// CLI-process tests for the automatic task-difficulty pass that runs next to
/// auto-naming when `cmux hooks claude auto-name` fires at turn end.
@Suite(.serialized)
struct CLIDifficultyAssessmentHookTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    private static let workspaceId = "11111111-1111-1111-1111-111111111111"
    private static let surfaceId = "22222222-2222-2222-2222-222222222222"

    private struct Probe {
        var enabled = true
        var manual = false
        var overridePresent = false
    }

    private struct Run {
        let commands: [String]

        func priorityParams() -> [[String: Any]] {
            commands.compactMap { line -> [String: Any]? in
                guard let payload = Harness.jsonObject(line),
                      payload["method"] as? String == "session_priority.set",
                      let params = payload["params"] as? [String: Any],
                      params["probe"] == nil else { return nil }
                return params
            }
        }

        func sentMethods() -> [String] {
            commands.compactMap { Harness.jsonObject($0)?["method"] as? String }
        }
    }

    @Test func skipsWhenProbeSaysDisabled() throws {
        let run = try perform(probe: Probe(enabled: false), answer: "Hard.")
        #expect(run.sentMethods().contains("session_priority.set"), "the probe must still be sent")
        #expect(run.priorityParams().isEmpty)
    }

    @Test func skipsWhenOverridePresent() throws {
        let run = try perform(probe: Probe(overridePresent: true), answer: "Hard.")
        #expect(run.sentMethods().contains("session_priority.set"), "the probe must still be sent")
        #expect(run.priorityParams().isEmpty)
    }

    @Test func sendsAutoDifficultyOnAParsableAnswer() throws {
        let run = try perform(probe: Probe(), answer: "Hard.")
        let params = run.priorityParams()
        #expect(params.count == 1)
        #expect(params.first?["difficulty"] as? String == "hard")
        #expect(params.first?["source"] as? String == "auto")
        #expect(params.first?["workspace_id"] as? String == Self.workspaceId)
        #expect(
            run.sentMethods().contains("workspace.set_auto_title"),
            "auto-naming must still have run; saw \(run.sentMethods())"
        )
    }

    @Test func doesNotSendOnAnUnparsableAnswer() throws {
        let run = try perform(probe: Probe(), answer: "This looks like a fairly hard task overall.")
        #expect(run.sentMethods().contains("session_priority.set"), "the probe must still be sent")
        #expect(run.priorityParams().isEmpty)
    }

    private func perform(probe: Probe, answer: String) throws -> Run {
        let context = try Harness.makeContext(name: "difficulty-hook")
        defer { context.cleanup() }
        let sessionId = "difficulty-hook-session"
        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: Self.workspaceId,
            surfaceId: Self.surfaceId,
            cwd: context.root.path
        )

        let transcript = context.root.appendingPathComponent("transcript.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Redesign the sync engine across modules"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will start by mapping the dependencies."}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let fakeClaude = context.root.appendingPathComponent("fake-claude")
        let script = "#!/bin/sh\ncat >/dev/null 2>&1\nprintf '%s\\n' '\(answer)'\n"
        try script.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        _ = Harness.startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = Harness.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else { return "OK" }
            switch method {
            case "workspace.set_auto_title":
                return Harness.v2Response(id: id, ok: true, result: ["enabled": true])
            case "session_priority.set":
                let params = payload["params"] as? [String: Any] ?? [:]
                if params["probe"] as? Bool == true {
                    return Harness.v2Response(id: id, ok: true, result: [
                        "enabled": probe.enabled,
                        "workspace_id": Self.workspaceId,
                        "manual": probe.manual,
                        "override_present": probe.overridePresent,
                    ])
                }
                return Harness.v2Response(id: id, ok: true, result: [:])
            case "surface.list":
                return Harness.v2Response(id: id, ok: true, result: [
                    "surfaces": [["id": Self.surfaceId, "ref": "surface:1", "focused": true]],
                ])
            default:
                return Harness.v2Response(id: id, ok: false, error: ["code": "not_found", "message": method])
            }
        }

        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = Self.workspaceId
        environment["CMUX_SURFACE_ID"] = Self.surfaceId
        environment["CMUX_CLAUDE_PID"] = "43301"
        environment["CMUX_CUSTOM_CLAUDE_PATH"] = fakeClaude.path
        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "auto-name"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"Stop","cwd":"\#(context.root.path)","transcript_path":"\#(transcript.path)"}"#
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        return Run(commands: context.state.snapshot())
    }
}
