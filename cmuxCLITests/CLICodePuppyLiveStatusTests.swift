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
        ("tool-start", "PreToolUse", "read_file"),
        ("tool-end", "PostToolUse", "Running"),
        ("stop", "Stop", "Idle"),
        ("stop", "SubagentStop", "Idle"),
        ("stop", "Stop", "Code Puppy error"),
        ("session-end", "SessionEnd", ""),
        ("session-update", "PostAutosave", "Existing"),
        ("session-update", "PostAutosave", "Fresh"),
        ("session-update", "PostAutosave", "Fresh error"),
        ("session-update", "PostAutosave", "Fresh missing")
    ])
    func lifecycleProjectsStatusAndFeed(_ subcommand: String, _ event: String, _ status: String) throws {
        let context = try Harness.makeContext(name: "puppy-status")
        defer { context.cleanup() }
        let sessionID = "puppy-turn"
        let autosaves = context.root.appendingPathComponent(".code_puppy/autosaves")
        try FileManager.default.createDirectory(at: autosaves, withIntermediateDirectories: true)
        if status != "Fresh missing" {
            try Data("durable session fixture".utf8).write(to: autosaves.appendingPathComponent(sessionID + ".pkl"))
        }
        let storeURL = context.root.appendingPathComponent("code-puppy-hook-sessions.json")
        let failed = status == "Code Puppy error" || status == "Fresh error"
        let commands = try Self.runHook(
            context: context, agent: "code-puppy", subcommand: subcommand, event: event,
            sessionID: sessionID, seedsRunningSession: !status.hasPrefix("Fresh"),
            extraPayload: failed ? ["success": false, "error": "tool exploded"] : [:]
        )
        if subcommand == "session-update" {
            #expect(!commands.contains { $0.hasPrefix("set_status ") || $0.hasPrefix("clear_agent_pid ") || $0.hasPrefix("agent_journal_append ") })
            let bindings = commands.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            if status == "Fresh missing" {
                #expect(!bindings.contains { $0["method"] as? String == "surface.resume.set" })
                #expect(!FileManager.default.fileExists(atPath: storeURL.path))
                return
            }
            #expect(bindings.contains { $0["method"] as? String == "surface.resume.set" && ($0["params"] as? [String: Any])?["checkpoint_id"] as? String == sessionID })
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
        if subcommand == "tool-start" || subcommand == "tool-end" {
            let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
            let sessions = try #require(saved["sessions"] as? [String: Any])
            let current = try #require(sessions[sessionID] as? [String: Any])
            // Tool activity is NOT another prompt: it must never increase prompt depth.
            #expect(current["activePromptDepth"] as? Int == 1)
            #expect(feedEvents.contains { $0["tool_name"] as? String == "read_file" })
            if subcommand == "tool-end" {
                #expect(feedEvents.contains(where: Self.carriesSanitizedToolResult))
            }
        }
    }

    /// Code Puppy's tool-status and explicit-outcome lanes must not leak into
    /// agents that already send the shared subcommands or `success` fields.
    @Test(arguments: [
        ("codex", "pre-tool-use", "PreToolUse"),
        ("codex", "post-tool-use", "PostToolUse"),
        ("gemini", "stop", "AfterAgent")
    ])
    func otherAgentsKeepTheirSharedSubcommandBehavior(_ agent: String, _ subcommand: String, _ event: String) throws {
        let context = try Harness.makeContext(name: "puppy-isolation")
        defer { context.cleanup() }
        let commands = try Self.runHook(
            context: context, agent: agent, subcommand: subcommand, event: event,
            sessionID: "\(agent)-turn", seedsRunningSession: true,
            extraPayload: ["success": false, "error": "tool exploded"]
        )
        if subcommand != "stop" {
            // Tool hooks stay status-silent for agents other than Code Puppy.
            #expect(!commands.contains { $0.hasPrefix("set_status \(agent) ") })
        }
        // Only Code Puppy turns an explicit `success:false` into an error outcome.
        #expect(!commands.contains { $0.contains("tool exploded") })
        let feedEvents = commands.compactMap { line -> [String: Any]? in
            guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  request["method"] as? String == "feed.push",
                  let params = request["params"] as? [String: Any] else { return nil }
            return params["event"] as? [String: Any]
        }
        // Feed keeps the agent's own tool input instead of the tool result.
        #expect(!feedEvents.contains(where: Self.carriesSanitizedToolResult))
    }

    private static func carriesSanitizedToolResult(_ event: [String: Any]) -> Bool {
        let summary = event["tool_input"] as? [String: Any]
        return summary?["_cmux_sanitized"] as? Bool == true
            && summary?["_cmux_value"] as? String == "file contents"
    }

    /// Runs one hook subcommand against a fake cmux socket and returns the commands it sent.
    private static func runHook(
        context: Harness.Context,
        agent: String,
        subcommand: String,
        event: String,
        sessionID: String,
        seedsRunningSession: Bool,
        extraPayload: [String: Any]
    ) throws -> [String] {
        if seedsRunningSession {
            let record: [String: Any] = [
                "sessionId": sessionID, "workspaceId": workspace, "surfaceId": surface,
                "cwd": context.root.path, "pid": Int(getpid()), "isRestorable": true,
                "startedAt": Date.now.timeIntervalSince1970, "updatedAt": Date.now.timeIntervalSince1970,
                "agentLifecycle": "running", "activePromptDepth": subcommand == "prompt-submit" ? 0 : 1
            ]
            try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": [sessionID: record]])
                .write(to: context.root.appendingPathComponent("\(agent)-hook-sessions.json"))
        }
        let handled = Harness.startDeliveryTargetServer(
            context: context, surfacesByWorkspace: [workspace: [surface]],
            pidTarget: (workspaceId: workspace, surfaceId: surface)
        )
        let pidKey = "CMUX_" + agent.uppercased().replacingOccurrences(of: "-", with: "_") + "_PID"
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = context.root.path
        environment[pidKey] = String(getpid())
        environment["CMUX_AGENT_LAUNCH_KIND"] = agent
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/\(agent)"
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = Data("/usr/local/bin/\(agent)\u{0}".utf8).base64EncodedString()
        var payloadObject: [String: Any] = [
            "session_id": sessionID, "hook_event_name": event, "tool_name": "read_file",
            "tool_input": ["path": "README.md"], "tool_result": "file contents", "cwd": context.root.path
        ]
        payloadObject.merge(extraPayload) { _, new in new }
        let payload = try JSONSerialization.data(withJSONObject: payloadObject)
        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", agent, subcommand, "--workspace", workspace, "--surface", surface],
            environment: environment, standardInput: String(decoding: payload, as: UTF8.self)
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        return context.state.snapshot()
    }
}
