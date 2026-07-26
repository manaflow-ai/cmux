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

    private func runHook(
        context: ClaudeHookLiveDeliveryHarness.Context,
        environment: [String: String],
        sessionId: String,
        toolName: String
    ) -> ClaudeHookLiveDeliveryHarness.ProcessRunResult {
        ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "task-sync"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PostToolUse","tool_name":"\#(toolName)"}"#
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
