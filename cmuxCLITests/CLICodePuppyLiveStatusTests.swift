import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLICodePuppyLiveStatusTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness
    private static let workspace = "11111111-1111-1111-1111-111111111111"
    private static let surface = "22222222-2222-2222-2222-222222222222"

    @Test(arguments: [
        ("prompt-submit", "UserPromptSubmit", "Running"),
        ("pre-tool-use", "PreToolUse", "read_file"),
        ("post-tool-use", "PostToolUse", "Running"),
        ("stop", "Stop", "Idle"),
        ("stop", "SubagentStop", "Idle"),
        ("stop", "Stop", "Code Puppy error"),
        ("session-end", "SessionEnd", ""),
        ("session-update", "PostAutosave", "Existing"),
        ("session-update", "PostAutosave", "Fresh"),
        ("session-update", "PostAutosave", "Fresh error")
    ])
    func lifecycleProjectsStatusAndFeed(_ subcommand: String, _ event: String, _ status: String) throws {
        let context = try Harness.makeContext(name: "puppy-status")
        defer { context.cleanup() }
        let sessionID = "puppy-turn"
        let autosaves = context.root.appendingPathComponent(".code_puppy/autosaves")
        try FileManager.default.createDirectory(at: autosaves, withIntermediateDirectories: true)
        try Data("durable session fixture".utf8).write(to: autosaves.appendingPathComponent(sessionID + ".pkl"))
        let storeURL = context.root.appendingPathComponent("code-puppy-hook-sessions.json")
        let record: [String: Any] = [
            "sessionId": sessionID, "workspaceId": Self.workspace, "surfaceId": Self.surface,
            "cwd": context.root.path, "pid": Int(getpid()), "isRestorable": true,
            "startedAt": Date.now.timeIntervalSince1970, "updatedAt": Date.now.timeIntervalSince1970,
            "agentLifecycle": "running", "activePromptDepth": subcommand == "prompt-submit" ? 0 : 1
        ]
        if !status.hasPrefix("Fresh") {
            try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [sessionID: record]])
                .write(to: storeURL)
        }
        let handled = Harness.startDeliveryTargetServer(
            context: context, surfacesByWorkspace: [Self.workspace: [Self.surface]],
            pidTarget: (workspaceId: Self.workspace, surfaceId: Self.surface)
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment["CMUX_CODE_PUPPY_PID"] = String(getpid())
        var payloadObject: [String: Any] = [
            "session_id": sessionID, "hook_event_name": event, "tool_name": "read_file",
            "tool_input": ["path": "README.md"], "tool_result": "file contents", "cwd": context.root.path
        ]
        if status == "Code Puppy error" || status == "Fresh error" {
            payloadObject["success"] = false
            payloadObject["error"] = "tool exploded"
        }
        let payload = try JSONSerialization.data(withJSONObject: payloadObject)
        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "code-puppy", subcommand, "--workspace", Self.workspace, "--surface", Self.surface],
            environment: environment, standardInput: String(decoding: payload, as: UTF8.self)
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let commands = context.state.snapshot()
        if subcommand == "session-update" {
            #expect(!commands.contains { $0.hasPrefix("set_status ") || $0.hasPrefix("clear_agent_pid ") || $0.hasPrefix("agent_journal_append ") })
            let bindings = commands.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            #expect(bindings.contains { $0["method"] as? String == "surface.resume_binding.set" })
            let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
            let sessions = try #require(saved["sessions"] as? [String: Any])
            let current = try #require(sessions[sessionID] as? [String: Any])
            #expect(current["isRestorable"] as? Bool == true)
            #expect(current["agentLifecycle"] as? String == (status == "Existing" ? "running" : (status == "Fresh error" ? "needsInput" : "idle")))
            #expect(current["activePromptDepth"] as? Int == (status == "Existing" ? 1 : nil))
        } else if subcommand == "session-end" {
            #expect(commands.contains { $0.hasPrefix("clear_agent_pid code-puppy.") && $0.contains("--clear-status") })
        } else {
            #expect(commands.contains {
                $0.hasPrefix("set_status code-puppy \(status) ")
                    || $0.hasPrefix("set_status code-puppy \"\(status)\" ")
            })
        }
        if subcommand == "stop" {
            let body = status == "Code Puppy error" ? "tool exploded" : "Task completed"
            #expect(commands.contains { $0.hasPrefix("agent_journal_append ") && $0.contains("notification") && $0.contains(body) })
        }
        let feedEvents = commands.compactMap { line -> [String: Any]? in
            guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  request["method"] as? String == "feed.push",
                  let params = request["params"] as? [String: Any] else { return nil }
            return params["event"] as? [String: Any]
        }
        if subcommand == "session-update" {
            #expect(feedEvents.isEmpty)
        } else {
            #expect(feedEvents.contains { $0["hook_event_name"] as? String == (event == "SubagentStop" ? "Stop" : event) })
        }
        if subcommand == "pre-tool-use" || subcommand == "post-tool-use" {
            let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
            let sessions = try #require(saved["sessions"] as? [String: Any])
            let current = try #require(sessions[sessionID] as? [String: Any])
            // Tool activity is NOT another prompt: it must never increase prompt depth.
            #expect(current["activePromptDepth"] as? Int == 1)
            #expect(feedEvents.contains { $0["tool_name"] as? String == "read_file" })
            if subcommand == "post-tool-use" {
                #expect(feedEvents.contains {
                    let summary = $0["tool_input"] as? [String: Any]
                    return summary?["_cmux_sanitized"] as? Bool == true
                        && summary?["_cmux_value"] as? String == "file contents"
                })
            }
        }
    }
}
