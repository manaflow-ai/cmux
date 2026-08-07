import Dispatch
import Foundation
import Testing

@Suite(.serialized)
struct ClaudeTaskSyncHookTests {
    @Test("Task-tool hooks publish one authoritative snapshot to Feed and workspace todos")
    func publishesAuthoritativeSnapshot() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync")
        defer { context.cleanup() }
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "task-sync-session"
        let mutationSeen = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )

        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"First task","activeForm":"Running first task","status":"in_progress"}"#,
            named: "1.json",
            in: taskDirectory
        )
        try writeTask(
            #"{"id":"2","subject":"Second task","activeForm":"Running second task","status":"pending"}"#,
            named: "2.json",
            in: taskDirectory
        )

        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        let firstResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        #expect(!firstResult.timedOut, Comment(rawValue: firstResult.stderr))
        #expect(firstResult.status == 0, Comment(rawValue: firstResult.stderr))
        #expect(firstResult.stdout == "{}\n")
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)

        let firstReconcile = try #require(reconcileRequests(in: context).last)
        #expect(firstReconcile["owner_id"] as? String == "claude:\(sessionId)")
        let firstItems = try #require(firstReconcile["items"] as? [[String: Any]])
        #expect(firstItems.count == 2)
        #expect(firstItems.compactMap { $0["text"] as? String } == ["Running first task", "Second task"])
        #expect(firstItems.compactMap { $0["state"] as? String } == ["in-progress", "pending"])
        #expect(firstItems.allSatisfy { $0["origin"] as? String == "agent" })
        let firstTaskId = try #require(firstItems.first?["id"] as? String)
        #expect(UUID(uuidString: firstTaskId) != nil)

        try writeTask(
            #"{"id":"1","subject":"First task","activeForm":"Running first task","status":"completed"}"#,
            named: "1.json",
            in: taskDirectory
        )
        try writeTask(
            #"{"id":"2","subject":"Second task","activeForm":"Running second task","status":"deleted"}"#,
            named: "2.json",
            in: taskDirectory
        )
        try writeTask(
            #"{"id":"3","subject":"Third task","activeForm":"Running third task","status":"pending"}"#,
            named: "3.json",
            in: taskDirectory
        )
        let secondResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )
        #expect(!secondResult.timedOut, Comment(rawValue: secondResult.stderr))
        #expect(secondResult.status == 0, Comment(rawValue: secondResult.stderr))
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)

        let secondReconcile = try #require(reconcileRequests(in: context).last)
        let secondItems = try #require(secondReconcile["items"] as? [[String: Any]])
        #expect(secondItems.compactMap { $0["text"] as? String } == ["First task", "Third task"])
        #expect(secondItems.compactMap { $0["state"] as? String } == ["completed", "pending"])
        #expect(secondItems.first?["id"] as? String == firstTaskId)

        let feedEvents = context.state.snapshot().compactMap(feedEvent)
        #expect(feedEvents.count == 2)
        #expect(feedEvents.allSatisfy { $0["hook_event_name"] as? String == "TodoWrite" })
        let latestInput = try #require(feedEvents.last?["tool_input"] as? [String: Any])
        let latestTodos = try #require(latestInput["todos"] as? [[String: Any]])
        #expect(latestTodos.compactMap { $0["id"] as? String } == ["1", "3"])

        let lockFiles = try FileManager.default.contentsOfDirectory(
            atPath: context.root.appendingPathComponent(".claude/tasks").path
        ).filter { $0.hasPrefix(".cmux-task-sync") }
        #expect(lockFiles == [".cmux-task-sync.lock"])
    }

    @Test("Snapshots over the checklist cap are sent whole for atomic rejection")
    func doesNotPublishTruncatedSnapshot() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-cap")
        defer { context.cleanup() }
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let surfaceId = "44444444-4444-4444-4444-444444444444"
        let sessionId = "task-sync-cap-session"
        let mutationSeen = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        for id in 1...51 {
            try writeTask(
                #"{"id":"\#(id)","subject":"Task \#(id)","status":"pending"}"#,
                named: "\(id).json",
                in: taskDirectory
            )
        }
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskList"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        let request = try #require(reconcileRequests(in: context).last)
        let items = try #require(request["items"] as? [[String: Any]])
        #expect(items.count == 51)
    }

    @Test("Team task directories bind by exact task identity and remain bound")
    func resolvesTeamTaskDirectoryByTaskIdentity() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-team")
        defer { context.cleanup() }
        let workspaceId = "55555555-5555-5555-5555-555555555555"
        let surfaceId = "66666666-6666-6666-6666-666666666666"
        let sessionId = "unrelated-hook-session"
        let mutationSeen = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path
        )

        let tasksRoot = context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        let teamDirectory = tasksRoot.appendingPathComponent("session-team-a", isDirectory: true)
        let neighboringDirectory = tasksRoot.appendingPathComponent("session-team-b", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighboringDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Team task","activeForm":"Running team task","status":"in_progress"}"#,
            named: "1.json",
            in: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Neighbor task","status":"pending"}"#,
            named: "1.json",
            in: neighboringDirectory
        )

        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        let createResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate",
            standardInput: #"{"session_id":"unrelated-hook-session","hook_event_name":"PostToolUse","tool_name":"TaskCreate","tool_input":{"subject":"Team task","description":"probe"},"tool_response":{"task":{"id":"1","subject":"Team task"}}}"#
        )

        #expect(!createResult.timedOut, Comment(rawValue: createResult.stderr))
        #expect(createResult.status == 0, Comment(rawValue: createResult.stderr))
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        let createdItems = try #require(reconcileRequests(in: context).last?["items"] as? [[String: Any]])
        #expect(createdItems.compactMap { $0["text"] as? String } == ["Running team task"])
        let boundRecord = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        )
        #expect(boundRecord["claudeTaskDirectoryName"] as? String == "session-team-a")

        try writeTask(
            #"{"id":"1","subject":"Team task","activeForm":"Running team task","status":"completed"}"#,
            named: "1.json",
            in: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Team task","status":"pending"}"#,
            named: "1.json",
            in: neighboringDirectory
        )
        let updateResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate",
            standardInput: #"{"session_id":"unrelated-hook-session","hook_event_name":"PostToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"completed"}}"#
        )

        #expect(!updateResult.timedOut, Comment(rawValue: updateResult.stderr))
        #expect(updateResult.status == 0, Comment(rawValue: updateResult.stderr))
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        let updatedItems = try #require(reconcileRequests(in: context).last?["items"] as? [[String: Any]])
        #expect(updatedItems.compactMap { $0["text"] as? String } == ["Team task"])
        #expect(updatedItems.compactMap { $0["state"] as? String } == ["completed"])

        try FileManager.default.removeItem(at: teamDirectory.appendingPathComponent("1.json"))
        let deleteResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate",
            standardInput: #"{"session_id":"unrelated-hook-session","hook_event_name":"PostToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"deleted"},"tool_response":{"task":{"id":"1","subject":"Team task","status":"deleted"}}}"#
        )

        #expect(!deleteResult.timedOut, Comment(rawValue: deleteResult.stderr))
        #expect(deleteResult.status == 0, Comment(rawValue: deleteResult.stderr))
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        let deletedItems = try #require(reconcileRequests(in: context).last?["items"] as? [[String: Any]])
        #expect(deletedItems.isEmpty)
    }

    @Test("An ambiguous team task identity publishes no todo mutation")
    func rejectsAmbiguousTeamTaskDirectory() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-ambiguous")
        defer { context.cleanup() }
        let workspaceId = "77777777-7777-7777-7777-777777777777"
        let surfaceId = "88888888-8888-8888-8888-888888888888"
        let sessionId = "ambiguous-hook-session"
        _ = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path
        )

        let tasksRoot = context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        for directoryName in ["session-team-a", "session-team-b"] {
            let directory = tasksRoot.appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeTask(
                #"{"id":"1","subject":"Shared task","status":"pending"}"#,
                named: "1.json",
                in: directory
            )
        }

        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        let result = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate",
            standardInput: #"{"session_id":"ambiguous-hook-session","hook_event_name":"PostToolUse","tool_name":"TaskCreate","tool_input":{"subject":"Shared task"},"tool_response":{"task":{"id":"1","subject":"Shared task"}}}"#
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let mutationMethods = context.state.snapshot().compactMap { line -> String? in
            guard let method = jsonObject(line)?["method"] as? String,
                  method == "feed.push" || method == "workspace.todo.reconcile" else { return nil }
            return method
        }
        #expect(mutationMethods.isEmpty)
        let record = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
        )
        #expect(record["claudeTaskDirectoryName"] == nil)
    }

    @Test("Configured shared task lists keep one identity while the leader remains active")
    func usesConfiguredSharedTaskListIdentity() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-shared")
        defer { context.cleanup() }
        let workspaceId = "99999999-9999-9999-9999-999999999999"
        let surfaceId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let taskListID = "shared/task list"
        let taskDirectoryName = "shared-task-list"
        let mutationSeen = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(taskDirectoryName)", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Shared task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )

        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CLAUDE_CODE_TASK_LIST_ID"] = taskListID
        let leaderSessionId = "shared-list-leader"
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: leaderSessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            markActive: true
        )
        let leaderResult = runHook(
            context: context,
            environment: environment,
            sessionId: leaderSessionId,
            toolName: "TaskList"
        )
        #expect(!leaderResult.timedOut, Comment(rawValue: leaderResult.stderr))
        #expect(leaderResult.status == 0, Comment(rawValue: leaderResult.stderr))
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)

        try writeTask(
            #"{"id":"1","subject":"Shared task","activeForm":"Updating shared task","status":"in_progress"}"#,
            named: "1.json",
            in: taskDirectory
        )
        var nestedEnvironment = environment
        nestedEnvironment["CMUX_AGENT_MANAGED_SUBAGENT"] = "1"
        let teammateSessionId = "shared-list-teammate"
        let teammateResult = runHook(
            context: context,
            environment: nestedEnvironment,
            sessionId: teammateSessionId,
            toolName: "TaskUpdate"
        )
        #expect(!teammateResult.timedOut, Comment(rawValue: teammateResult.stderr))
        #expect(teammateResult.status == 0, Comment(rawValue: teammateResult.stderr))
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)

        try FileManager.default.removeItem(at: taskDirectory.appendingPathComponent("1.json"))
        let deletionSessionId = "shared-list-deletion"
        let deletionResult = runHook(
            context: context,
            environment: environment,
            sessionId: deletionSessionId,
            toolName: "TaskUpdate",
            standardInput: #"{"session_id":"shared-list-deletion","hook_event_name":"PostToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"deleted"}}"#
        )
        #expect(!deletionResult.timedOut, Comment(rawValue: deletionResult.stderr))
        #expect(deletionResult.status == 0, Comment(rawValue: deletionResult.stderr))
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)

        let reconciliations = reconcileRequests(in: context)
        #expect(reconciliations.count == 3)
        #expect(reconciliations.allSatisfy {
            $0["owner_id"] as? String == "claude:\(taskDirectoryName)"
        })
        let leaderItems = try #require(reconciliations.first?["items"] as? [[String: Any]])
        let teammateItems = try #require(reconciliations.dropFirst().first?["items"] as? [[String: Any]])
        let deletionItems = try #require(reconciliations.last?["items"] as? [[String: Any]])
        #expect(leaderItems.first?["id"] as? String == teammateItems.first?["id"] as? String)
        #expect(deletionItems.isEmpty)

        let feedSessionIds = context.state.snapshot().compactMap(feedEvent)
            .compactMap { $0["session_id"] as? String }
        #expect(feedSessionIds == [
            "claude-\(leaderSessionId)",
            "claude-\(teammateSessionId)",
            "claude-\(deletionSessionId)",
        ])
        for sessionId in [leaderSessionId, teammateSessionId, deletionSessionId] {
            let record = try #require(
                try ClaudeHookLiveDeliveryHarness.sessionRecord(in: context.storeURL, sessionId: sessionId)
            )
            #expect(record["claudeTaskDirectoryName"] as? String == taskDirectoryName)
        }
    }

    @Test("Automatic teams resolve their shared task list from the hook agent id")
    func resolvesAutomaticTeamTaskListFromAgentID() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-auto-team")
        defer { context.cleanup() }
        let workspaceId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let surfaceId = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let leaderSessionId = "automatic-team-leader"
        let teammateSessionId = "automatic-team-teammate"
        let teammateAgentId = "agent-teammate"
        let teamName = "session-automatic-team"
        let mutationSeen = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: leaderSessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            markActive: true
        )

        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(teamName)", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Claim shared task","activeForm":"Claiming shared task","status":"in_progress"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/\(teamName)", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try Data(
            #"{"name":"\#(teamName)","members":[{"agentId":"\#(teammateAgentId)"}]}"#.utf8
        ).write(to: teamDirectory.appendingPathComponent("config.json"))

        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_MANAGED_SUBAGENT"] = "1"
        let result = runHook(
            context: context,
            environment: environment,
            sessionId: teammateSessionId,
            toolName: "TaskUpdate",
            standardInput: #"{"session_id":"\#(teammateSessionId)","hook_event_name":"PostToolUse","agent_id":"\#(teammateAgentId)","tool_name":"TaskUpdate","tool_input":{"taskId":"1","owner":"teammate","status":"in_progress"},"tool_response":{"success":true,"taskId":"1","updatedFields":["owner","status"],"statusChange":{"from":"pending","to":"in_progress"}}}"#
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        let reconciliation = try #require(reconcileRequests(in: context).last)
        #expect(reconciliation["owner_id"] as? String == "claude:\(teamName)")
        let items = try #require(reconciliation["items"] as? [[String: Any]])
        #expect(items.compactMap { $0["text"] as? String } == ["Claiming shared task"])
        let record = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: teammateSessionId
            )
        )
        #expect(record["claudeTaskDirectoryName"] as? String == teamName)
    }

    @Test("An all-completed snapshot preserves Feed history and clears workspace-owned todos")
    func clearsWorkspaceOwnerForAllCompletedSnapshot() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-completed")
        defer { context.cleanup() }
        let workspaceId = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        let surfaceId = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        let sessionId = "completed-list-session"
        let taskListID = "completed-list"
        let mutationSeen = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(taskListID)", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Finished task","status":"completed"}"#,
            named: "1.json",
            in: taskDirectory
        )

        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CLAUDE_CODE_TASK_LIST_ID"] = taskListID
        let result = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        #expect(mutationSeen.wait(timeout: .now() + 5) == .success)
        let feedTodos = context.state.snapshot().compactMap(feedEvent)
            .compactMap { $0["tool_input"] as? [String: Any] }
            .compactMap { $0["todos"] as? [[String: Any]] }
            .last
        #expect(feedTodos?.compactMap { $0["status"] as? String } == ["completed"])
        let checklistItems = try #require(
            reconcileRequests(in: context).last?["items"] as? [[String: Any]]
        )
        #expect(checklistItems.isEmpty)
    }

    private func runHook(
        context: ClaudeHookLiveDeliveryHarness.Context,
        environment: [String: String],
        sessionId: String,
        toolName: String,
        standardInput: String? = nil
    ) -> ClaudeHookLiveDeliveryHarness.ProcessRunResult {
        ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "task-sync"],
            environment: environment,
            standardInput: standardInput
                ?? #"{"session_id":"\#(sessionId)","hook_event_name":"PostToolUse","tool_name":"\#(toolName)"}"#
        )
    }

    private func writeTask(_ json: String, named name: String, in directory: URL) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent(name))
    }

    private func reconcileRequests(in context: ClaudeHookLiveDeliveryHarness.Context) -> [[String: Any]] {
        context.state.snapshot().compactMap { line in
            guard let request = jsonObject(line),
                  request["method"] as? String == "workspace.todo.reconcile" else { return nil }
            return request["params"] as? [String: Any]
        }
    }

    private func feedEvent(_ line: String) -> [String: Any]? {
        guard let request = jsonObject(line),
              request["method"] as? String == "feed.push",
              let params = request["params"] as? [String: Any] else { return nil }
        return params["event"] as? [String: Any]
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
}
