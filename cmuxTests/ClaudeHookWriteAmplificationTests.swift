import Foundation
import Testing

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/9693.
/// Repeated ordinary Claude tool calls must not turn an already-running
/// lifecycle observation into durable Feed telemetry or a session-file write.
@Suite(.serialized)
struct ClaudeHookWriteAmplificationTests {
    private typealias Harness = ClaudeHookLiveDeliveryHarness

    @Test func ordinaryToolUseWhileRunningDoesNotWriteDurableState() throws {
        let context = try Harness.makeContext(name: "pre-tool-write-amplification")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "ordinary-running-tool-session"
        let now = Date.now.timeIntervalSince1970
        let state: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "running",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        let stateData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try stateData.write(to: context.storeURL)

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(
            !context.state.snapshot().contains { command in
                command.contains(#""method":"feed.push""#)
                    || command.hasPrefix("set_status ")
                    || command.hasPrefix("set_agent_lifecycle ")
                    || command.hasPrefix("clear_notifications ")
            }
        )
        #expect(try Data(contentsOf: context.storeURL) == stateData)
    }

    @Test(arguments: ["PostToolUse", "PostToolUseFailure"])
    func blockingToolCompletionClearsNeedsInputWithoutFeedTelemetry(
        hookEventName: String
    ) throws {
        let context = try Harness.makeContext(name: "input-resolved-\(hookEventName)")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "resolved-blocking-tool-session"
        let now = Date.now.timeIntervalSince1970
        let state: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "needsInput",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: context.storeURL)

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "input-resolved"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"\#(hookEventName)","tool_name":"AskUserQuestion","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let commands = context.state.snapshot()
        #expect(!commands.contains { $0.contains(#""method":"feed.push""#) })
        #expect(commands.contains { command in
            guard let data = command.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return object["method"] as? String == "feed.attention.end"
        })
        #expect(!commands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(!commands.contains { $0.hasPrefix("set_agent_lifecycle ") })
        #expect(!commands.contains { $0.hasPrefix("set_status ") })
        let record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["agentLifecycle"] as? String == "running")
    }

    @Test func overlappingBlockingToolsClearNeedsInputOnlyAfterBothComplete() throws {
        let context = try Harness.makeContext(name: "overlapping-blocking-tools")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "overlapping-blocking-tool-session"
        let now = Date.now.timeIntervalSince1970
        let state: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "running",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: context.storeURL)

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        func runHook(
            subcommand: String,
            eventName: String,
            toolUseId: String
        ) -> Harness.ProcessRunResult {
            let result = Harness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"\#(eventName)","tool_name":"AskUserQuestion","tool_use_id":"\#(toolUseId)","cwd":"\#(context.root.path)"}"#
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
            return result
        }

        _ = runHook(subcommand: "pre-tool-use", eventName: "PreToolUse", toolUseId: "tool-b")
        _ = runHook(subcommand: "pre-tool-use", eventName: "PreToolUse", toolUseId: "tool-a")

        let pendingRecord = try Harness.sessionRecord(
            in: context.storeURL,
            sessionId: sessionId
        )
        #expect(pendingRecord?["agentLifecycle"] as? String == "needsInput")
        #expect(pendingRecord?["pendingBlockingToolUseIds"] as? [String] == ["tool-a", "tool-b"])

        let beforeFirstCompletion = context.state.snapshot().count
        _ = runHook(subcommand: "input-resolved", eventName: "PostToolUse", toolUseId: "tool-a")
        let firstCompletionCommands = Array(
            context.state.snapshot().dropFirst(beforeFirstCompletion)
        )
        #expect(!firstCompletionCommands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(
            !firstCompletionCommands.contains {
                $0.hasPrefix("set_agent_lifecycle claude_code running ")
            }
        )
        #expect(!firstCompletionCommands.contains { $0.hasPrefix("set_status claude_code ") })

        let stillPendingRecord = try Harness.sessionRecord(
            in: context.storeURL,
            sessionId: sessionId
        )
        #expect(stillPendingRecord?["agentLifecycle"] as? String == "needsInput")
        #expect(stillPendingRecord?["pendingBlockingToolUseIds"] as? [String] == ["tool-b"])

        let storeBeforeDuplicateCompletion = try Data(contentsOf: context.storeURL)
        let beforeDuplicateCompletion = context.state.snapshot().count
        _ = runHook(subcommand: "input-resolved", eventName: "PostToolUse", toolUseId: "tool-a")
        let duplicateCompletionCommands = Array(
            context.state.snapshot().dropFirst(beforeDuplicateCompletion)
        )
        #expect(!duplicateCompletionCommands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(
            !duplicateCompletionCommands.contains {
                $0.hasPrefix("set_agent_lifecycle claude_code running ")
            }
        )
        #expect(try Data(contentsOf: context.storeURL) == storeBeforeDuplicateCompletion)

        let beforeFinalCompletion = context.state.snapshot().count
        _ = runHook(subcommand: "input-resolved", eventName: "PostToolUse", toolUseId: "tool-b")
        let finalCompletionCommands = Array(
            context.state.snapshot().dropFirst(beforeFinalCompletion)
        )
        #expect(finalCompletionCommands.contains { command in
            guard let data = command.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "feed.attention.end",
                  let params = object["params"] as? [String: Any] else {
                return false
            }
            return params["request_id"] as? String == "tool-b"
        })
        #expect(!finalCompletionCommands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(!finalCompletionCommands.contains { $0.hasPrefix("set_agent_lifecycle ") })
        #expect(!finalCompletionCommands.contains { $0.hasPrefix("set_status ") })

        let resolvedRecord = try Harness.sessionRecord(
            in: context.storeURL,
            sessionId: sessionId
        )
        #expect(resolvedRecord?["agentLifecycle"] as? String == "running")
        #expect(resolvedRecord?["pendingBlockingToolUseIds"] as? [String] == [])
    }

    @Test func deniedPlanDoesNotPoisonTheNextBlockingTool() throws {
        let context = try Harness.makeContext(name: "denied-plan-blocker")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "denied-plan-blocker-session"
        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path
        )

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId],
            feedExitPlanModesByRequestId: [
                "rejected-plan": "deny",
                "accepted-plan": "manual",
            ]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        func runHook(
            subcommand: String,
            eventName: String,
            toolUseId: String
        ) -> Harness.ProcessRunResult {
            let result = Harness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"\#(eventName)","tool_name":"ExitPlanMode","tool_use_id":"\#(toolUseId)","permission_mode":"plan","cwd":"\#(context.root.path)"}"#
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            return result
        }

        _ = runHook(
            subcommand: "pre-tool-use",
            eventName: "PreToolUse",
            toolUseId: "rejected-plan"
        )
        let rejection = runHook(
            subcommand: "permission-request",
            eventName: "PermissionRequest",
            toolUseId: "rejected-plan"
        )
        #expect(rejection.stdout.contains(#""behavior":"deny""#))

        var record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == [])

        _ = runHook(
            subcommand: "pre-tool-use",
            eventName: "PreToolUse",
            toolUseId: "accepted-plan"
        )
        let approval = runHook(
            subcommand: "permission-request",
            eventName: "PermissionRequest",
            toolUseId: "accepted-plan"
        )
        #expect(approval.stdout.contains(#""behavior":"allow""#))

        record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["agentLifecycle"] as? String == "running")
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == [])

        let beforeLateCompletion = context.state.snapshot().count
        _ = runHook(
            subcommand: "input-resolved",
            eventName: "PostToolUse",
            toolUseId: "accepted-plan"
        )
        let lateCompletionCommands = Array(
            context.state.snapshot().dropFirst(beforeLateCompletion)
        )
        #expect(!lateCompletionCommands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(!lateCompletionCommands.contains { $0.hasPrefix("set_agent_lifecycle ") })
        #expect(!lateCompletionCommands.contains { $0.hasPrefix("set_status ") })
    }

    @Test func bypassCompletionUsesRequestScopedAttention() throws {
        let context = try Harness.makeContext(name: "request-scoped-attention")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "request-scoped-attention-session"
        let toolUseId = "bypass-question"
        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path
        )

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLAUDE_PID"] = "4242"

        func runHook(subcommand: String, eventName: String) -> Harness.ProcessRunResult {
            let result = Harness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"\#(eventName)","tool_name":"AskUserQuestion","tool_use_id":"\#(toolUseId)","permission_mode":"bypassPermissions","cwd":"\#(context.root.path)"}"#
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
            return result
        }

        let beforeNeedsInput = context.state.snapshot().count
        _ = runHook(subcommand: "pre-tool-use", eventName: "PreToolUse")
        let needsInputCommands = Array(context.state.snapshot().dropFirst(beforeNeedsInput))
        #expect(needsInputCommands.contains { command in
            guard let data = command.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "feed.attention.begin",
                  let params = object["params"] as? [String: Any] else {
                return false
            }
            return params["request_id"] as? String == toolUseId
                && params["ppid"] as? Int == 4242
        })
        #expect(!needsInputCommands.contains { $0.hasPrefix("set_agent_lifecycle ") })
        #expect(!needsInputCommands.contains { $0.hasPrefix("set_status ") })
        #expect(!needsInputCommands.contains { $0.hasPrefix("notify_target_async ") })

        let beforeCompletion = context.state.snapshot().count
        _ = runHook(subcommand: "input-resolved", eventName: "PostToolUse")
        let completionCommands = Array(context.state.snapshot().dropFirst(beforeCompletion))
        #expect(completionCommands.contains { command in
            guard let data = command.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "feed.attention.end",
                  let params = object["params"] as? [String: Any] else {
                return false
            }
            return params["request_id"] as? String == toolUseId
        })
        #expect(!completionCommands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(!completionCommands.contains { $0.hasPrefix("set_agent_lifecycle ") })
        #expect(!completionCommands.contains { $0.hasPrefix("set_status ") })
    }

    @Test func timedOutPermissionRequestRetiresItsCorrelatedBlocker() throws {
        let context = try Harness.makeContext(name: "timed-out-plan-blocker")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "timed-out-plan-blocker-session"
        let toolUseId = "timed-out-plan"
        try Harness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path
        )

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId],
            feedTerminalStatusesByRequestId: [toolUseId: "timed_out"]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        for (subcommand, eventName) in [
            ("pre-tool-use", "PreToolUse"),
            ("permission-request", "PermissionRequest"),
        ] {
            let result = Harness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"\#(eventName)","tool_name":"ExitPlanMode","tool_use_id":"\#(toolUseId)","permission_mode":"plan","cwd":"\#(context.root.path)"}"#
            )
            #expect(serverHandled.wait(timeout: .now() + 5) == .success)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
        }

        let record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["agentLifecycle"] as? String == "running")
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == [])
    }

    @Test func staleSessionEndDoesNotReleaseCurrentTurnBlocker() throws {
        let context = try Harness.makeContext(name: "stale-end-current-blocker")
        defer { context.cleanup() }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "stale-end-current-blocker-session"
        let now = Date.now.timeIntervalSince1970
        let state: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "needsInput",
                    "pendingBlockingToolUseIds": ["current-turn-tool"],
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
            "activeSessionsByWorkspace": [
                workspaceId: [
                    "sessionId": sessionId,
                    "turnId": "turn-2",
                    "updatedAt": now,
                ],
            ],
            "activeSessionsBySurface": [
                surfaceId: [
                    "sessionId": sessionId,
                    "turnId": "turn-2",
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: context.storeURL)

        let serverHandled = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","hook_event_name":"SessionEnd","cwd":"\#(context.root.path)"}"#
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "OK\n")
        #expect(
            !context.state.snapshot().contains { command in
                guard let data = command.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return false }
                return object["method"] as? String == "feed.attention.end"
            },
            "a stale SessionEnd must not release blockers owned by the current turn"
        )
        let record = try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        #expect(record?["agentLifecycle"] as? String == "needsInput")
        #expect(record?["pendingBlockingToolUseIds"] as? [String] == ["current-turn-tool"])
    }
}
