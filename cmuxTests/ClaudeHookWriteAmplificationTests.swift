import Darwin
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
        let now: TimeInterval = 4_102_444_800
        let state: [String: Any] = [
            "version": 1,
            "pendingCursorApprovalIndexInitialized": true,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "running",
                    "lastPermissionMode": "default",
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
        let initialAttributes = try FileManager.default.attributesOfItem(atPath: context.storeURL.path)
        let initialFileNumber = (initialAttributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let initialModificationDate = initialAttributes[.modificationDate] as? Date

        _ = Harness.startDeliveryTargetServer(
            context: context,
            surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil,
            surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        for _ in 0..<20 {
            let result = Harness.runHookProcess(
                context: context,
                arguments: ["hooks", "claude", "pre-tool-use"],
                environment: environment,
                standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","permission_mode":"default","cwd":"\#(context.root.path)"}"#
            )
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
        }
        #expect(
            !context.state.snapshot().contains { command in
                command.contains(#""method":"feed.push""#)
                    || command.hasPrefix("set_status ")
                    || command.hasPrefix("set_agent_lifecycle ")
                    || command.hasPrefix("clear_notifications ")
            }
        )
        #expect(try Data(contentsOf: context.storeURL) == stateData)
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: context.storeURL.path)
        #expect(
            (finalAttributes[.systemFileNumber] as? NSNumber)?.uint64Value == initialFileNumber,
            "An unchanged session must not be atomically replaced"
        )
        #expect(
            finalAttributes[.modificationDate] as? Date == initialModificationDate,
            "An unchanged session must not be rewritten"
        )
    }

    @Test(arguments: ["AskUserQuestion", "ExitPlanMode", "permission_prompt",
                      "permission_prompt_empty", "permission_prompt_write_failure"])
    func resumeClearsAttentionBeforeOrdinaryObservationsBecomeNoOps(_ trigger: String) throws {
        let context = try Harness.makeContext(name: "hook-resume-write-amplification")
        defer { context.cleanup() }
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "resume-write-amplification-session"
        try Harness.writeSessionStore(
            to: context.storeURL, sessionId: sessionId,
            workspaceId: workspaceId, surfaceId: surfaceId, cwd: context.root.path
        )
        let initialObject = try JSONSerialization.jsonObject(with: Data(contentsOf: context.storeURL))
        var initialState = try #require(initialObject as? [String: Any])
        var sessions = try #require(initialState["sessions"] as? [String: [String: Any]])
        sessions[sessionId]?["agentLifecycle"] = "running"
        sessions[sessionId]?["lastPermissionMode"] = "default"
        initialState["sessions"] = sessions
        initialState["pendingCursorApprovalIndexInitialized"] = true
        try JSONSerialization.data(withJSONObject: initialState, options: [.sortedKeys]).write(to: context.storeURL)
        let originalData = try Data(contentsOf: context.storeURL)
        _ = Harness.startDeliveryTargetServer(
            context: context, surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil, surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        let isPermissionPrompt = trigger.hasPrefix("permission_prompt")
        let isEmptyPrompt = trigger == "permission_prompt_empty"
        let isWriteFailure = trigger == "permission_prompt_write_failure"
        if isWriteFailure {
            try #require(chflags(context.storeURL.path, UInt32(UF_IMMUTABLE)) == 0)
        }
        defer { if isWriteFailure { _ = chflags(context.storeURL.path, 0) } }
        let message = isEmptyPrompt ? "" : "Bash needs approval"
        let blockingInput = isPermissionPrompt
            ? #"{"session_id":"\#(sessionId)","hook_event_name":"Notification","notification_type":"permission_prompt","message":"\#(message)","cwd":"\#(context.root.path)"}"#
            : #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"\#(trigger)","permission_mode":"bypassPermissions","cwd":"\#(context.root.path)"}"#
        let blocking = Harness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", isPermissionPrompt ? "notification" : "pre-tool-use"],
            environment: environment, standardInput: blockingInput
        )
        #expect(!blocking.timedOut, Comment(rawValue: blocking.stderr))
        try #require(blocking.status == 0, Comment(rawValue: blocking.stderr))
        #expect(context.state.snapshot().contains { $0.hasPrefix("set_status claude_code Needs input ") })
        if isWriteFailure {
            #expect(try Data(contentsOf: context.storeURL) == originalData, "Fixture must actually prevent persistence")
            try #require(chflags(context.storeURL.path, 0) == 0)
        } else {
            #expect(try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)?["agentLifecycle"] as? String == "needsInput")
        }
        #expect(context.state.snapshot().contains { $0.hasPrefix("notify_target_async ") })
        let beforeResumeCount = context.state.snapshot().count
        let ordinaryInput = #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","permission_mode":"default","cwd":"\#(context.root.path)"}"#
        let resumed = Harness.runHookProcess(
            context: context, arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment, standardInput: ordinaryInput
        )
        #expect(!resumed.timedOut, Comment(rawValue: resumed.stderr))
        try #require(resumed.status == 0, Comment(rawValue: resumed.stderr))
        #expect(try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId)?["agentLifecycle"] as? String == "running")
        let resumedCommands = context.state.snapshot().dropFirst(beforeResumeCount)
        #expect(resumedCommands.contains { $0 == "clear_notifications --tab=\(workspaceId) --panel=\(surfaceId)" })
        #expect(resumedCommands.contains { $0.hasPrefix("set_status claude_code Running ") })

        let runningData = try Data(contentsOf: context.storeURL)
        let runningAttributes = try FileManager.default.attributesOfItem(atPath: context.storeURL.path)
        let beforeNoOpCommands = mutations(in: context)
        for _ in 0..<5 {
            let result = Harness.runHookProcess(
                context: context, arguments: ["hooks", "claude", "pre-tool-use"],
                environment: environment, standardInput: ordinaryInput
            )
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
        }
        #expect(mutations(in: context) == beforeNoOpCommands)
        #expect(try Data(contentsOf: context.storeURL) == runningData)
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: context.storeURL.path)
        #expect(finalAttributes[.systemFileNumber] as? NSNumber == runningAttributes[.systemFileNumber] as? NSNumber)
        #expect(finalAttributes[.modificationDate] as? Date == runningAttributes[.modificationDate] as? Date)
    }

    @Test(arguments: [false, true])
    func runningObservationRehomesMovedSurfaceBeforeBecomingANoOp(_ hasDestinationOwner: Bool) throws {
        let context = try Harness.makeContext(name: "hook-running-pane-move")
        defer { context.cleanup() }
        let oldWorkspaceId = "11111111-1111-1111-1111-111111111111"
        let newWorkspaceId = "33333333-3333-3333-3333-333333333333"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "running-moved-surface"
        let destinationSurfaceId = "44444444-4444-4444-4444-444444444444"
        let destinationSessionId = "destination-agent"
        let now: TimeInterval = 4_102_444_800
        let active: [String: Any] = ["sessionId": sessionId, "updatedAt": now]
        var state: [String: Any] = [
            "version": 1, "pendingCursorApprovalIndexInitialized": true,
            "sessions": [sessionId: [
                "sessionId": sessionId, "workspaceId": oldWorkspaceId,
                "surfaceId": surfaceId, "cwd": context.root.path,
                "agentLifecycle": "running", "lastPermissionMode": "default",
                "startedAt": now, "updatedAt": now,
            ]],
            "activeSessionsByWorkspace": [oldWorkspaceId: active],
            "activeSessionsBySurface": [surfaceId: active],
        ]
        if hasDestinationOwner {
            var sessions = try #require(state["sessions"] as? [String: [String: Any]])
            var destination = try #require(sessions[sessionId])
            destination["sessionId"] = destinationSessionId
            destination["workspaceId"] = newWorkspaceId
            destination["surfaceId"] = destinationSurfaceId
            sessions[destinationSessionId] = destination
            state["sessions"] = sessions
            let destinationActive: [String: Any] = [
                "sessionId": destinationSessionId, "turnId": "destination-turn", "updatedAt": now,
            ]
            state["activeSessionsByWorkspace"] = [oldWorkspaceId: active, newWorkspaceId: destinationActive]
            state["activeSessionsBySurface"] = [surfaceId: active, destinationSurfaceId: destinationActive]
        }
        try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: context.storeURL)
        _ = Harness.startDeliveryTargetServer(
            context: context, surfacesByWorkspace: [
                oldWorkspaceId: [], newWorkspaceId: hasDestinationOwner ? [surfaceId, destinationSurfaceId] : [surfaceId],
            ],
            pidTarget: nil, surfaceTargets: [surfaceId: newWorkspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = oldWorkspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        let input = #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","permission_mode":"default"}"#
        let moved = Harness.runHookProcess(
            context: context, arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment, standardInput: input
        )
        try #require(!moved.timedOut && moved.status == 0, Comment(rawValue: moved.stderr))
        #expect(moved.stdout == "{}\n")
        let record = try #require(try Harness.sessionRecord(in: context.storeURL, sessionId: sessionId))
        #expect(record["workspaceId"] as? String == newWorkspaceId)
        #expect(record["surfaceId"] as? String == surfaceId)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: context.storeURL)) as? [String: Any])
        let workspaces = try #require(saved["activeSessionsByWorkspace"] as? [String: [String: Any]])
        #expect(workspaces[oldWorkspaceId] == nil)
        #expect(workspaces[newWorkspaceId]?["sessionId"] as? String == (hasDestinationOwner ? destinationSessionId : sessionId))
        let surfaces = try #require(saved["activeSessionsBySurface"] as? [String: [String: Any]])
        #expect(surfaces[surfaceId]?["sessionId"] as? String == sessionId)
        if hasDestinationOwner {
            #expect(workspaces[newWorkspaceId]?["turnId"] as? String == "destination-turn")
            #expect(surfaces[destinationSurfaceId]?["sessionId"] as? String == destinationSessionId)
        }
        #expect(mutations(in: context).contains { $0.hasPrefix("set_status claude_code Running ") && $0.contains("--tab=\(newWorkspaceId)") })
        let baselineData = try Data(contentsOf: context.storeURL)
        let baselineMutations = mutations(in: context)
        let unchanged = Harness.runHookProcess(
            context: context, arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment, standardInput: input
        )
        #expect(!unchanged.timedOut && unchanged.status == 0, Comment(rawValue: unchanged.stderr))
        #expect(try Data(contentsOf: context.storeURL) == baselineData)
        #expect(mutations(in: context) == baselineMutations)
    }

    @Test(arguments: ["oversized-padding", "oversized-sessions", "oversized-retained-session", "legacy-surface"])
    func unchangedPermissionObservationPersistsLoadRepairs(_ repair: String) throws {
        let context = try Harness.makeContext(name: "hook-load-repair")
        defer { context.cleanup() }
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "load-repair-session"
        let now: TimeInterval = 4_102_444_800
        var record: [String: Any] = [
            "sessionId": sessionId, "workspaceId": workspaceId,
            "surfaceId": surfaceId, "cwd": context.root.path,
            "agentLifecycle": "running", "lastPermissionMode": "default",
            "startedAt": now, "updatedAt": now,
        ]
        if repair == "oversized-retained-session" {
            record["lastBody"] = String(repeating: "x", count: 8 * 1024 * 1024)
        }
        var sessions = [sessionId: record]
        if repair == "oversized-sessions" {
            for index in 0..<513 {
                var older = record
                let olderId = "older-\(index)"
                older["sessionId"] = olderId
                older["updatedAt"] = now - Double(index + 1)
                sessions[olderId] = older
            }
        }
        let active: [String: Any] = ["sessionId": sessionId, "updatedAt": now]
        var state: [String: Any] = [
            "version": 1, "pendingCursorApprovalIndexInitialized": true,
            "sessions": sessions, "activeSessionsByWorkspace": [workspaceId: active],
        ]
        if repair != "legacy-surface" {
            state["activeSessionsBySurface"] = [surfaceId: active]
        }
        var originalData = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        if repair.hasPrefix("oversized") {
            // Padding also exercises oversized JSON whose decoded model needs
            // no compaction: semantic equality alone cannot detect this repair.
            originalData.append(Data(repeating: 0x20, count: 8 * 1024 * 1024))
        }
        try originalData.write(to: context.storeURL)
        _ = Harness.startDeliveryTargetServer(
            context: context, surfacesByWorkspace: [workspaceId: [surfaceId]],
            pidTarget: nil, surfaceTargets: [surfaceId: workspaceId]
        )
        var environment = Harness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        // A read-only lookup must not persist the in-memory repair.
        let lookup = Harness.runHookProcess(
            context: context, arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash"}"#
        )
        try #require(!lookup.timedOut && lookup.status == 0, Comment(rawValue: lookup.stderr))
        #expect(try Data(contentsOf: context.storeURL) == originalData)

        let input = #"{"session_id":"\#(sessionId)","hook_event_name":"PreToolUse","tool_name":"Bash","permission_mode":"default"}"#
        let repaired = Harness.runHookProcess(
            context: context, arguments: ["hooks", "claude", "pre-tool-use"],
            environment: environment, standardInput: input
        )
        try #require(!repaired.timedOut && repaired.status == 0, Comment(rawValue: repaired.stderr))
        #expect(repaired.stdout == "{}\n")
        let repairedData = try Data(contentsOf: context.storeURL)
        #expect(repairedData != originalData, "An unchanged hook must still persist load-time repairs")
        let saved = try #require(JSONSerialization.jsonObject(with: repairedData) as? [String: Any])
        let savedSessions = try #require(saved["sessions"] as? [String: Any])
        if repair == "oversized-retained-session" {
            #expect(repairedData.count >= 8 * 1024 * 1024)
            let retained = try #require(savedSessions[sessionId] as? [String: Any])
            #expect((retained["lastBody"] as? String)?.count == 8 * 1024 * 1024)
        } else {
            #expect(repairedData.count < 8 * 1024 * 1024)
        }
        #expect(savedSessions.count == (repair == "oversized-sessions" ? 512 : 1))
        let savedSurfaces = try #require(saved["activeSessionsBySurface"] as? [String: [String: Any]])
        #expect(savedSurfaces[surfaceId]?["sessionId"] as? String == sessionId)
        let repairedAttributes = try FileManager.default.attributesOfItem(atPath: context.storeURL.path)

        for _ in 0..<5 {
            let result = Harness.runHookProcess(
                context: context, arguments: ["hooks", "claude", "pre-tool-use"],
                environment: environment, standardInput: input
            )
            #expect(!result.timedOut && result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
        }
        #expect(mutations(in: context).isEmpty)
        #expect(try Data(contentsOf: context.storeURL) == repairedData)
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: context.storeURL.path)
        #expect(finalAttributes[.systemFileNumber] as? NSNumber == repairedAttributes[.systemFileNumber] as? NSNumber)
        #expect(finalAttributes[.modificationDate] as? Date == repairedAttributes[.modificationDate] as? Date)
    }

    private func mutations(in context: Harness.Context) -> [String] {
        context.state.snapshot().filter { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return true
            }
            return object["method"] as? String != "agent.resolve_delivery_target"
        }
    }
}
