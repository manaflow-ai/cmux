import CMUXAgentLaunch
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
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
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
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let firstReconcile = try #require(reconcileRequests(in: context).last)
        #expect(firstReconcile["owner_id"] as? String == taskOwnerID(
            directoryName: sessionId,
            tasksRootURL: taskDirectory.deletingLastPathComponent()
        ))
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
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

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

        // The task-store scope namespaces durable claims, while the
        // cross-process lease uses one of a bounded set of deterministic files.
        let taskSyncLockPrefix = context.storeURL.lastPathComponent + ".task-sync.lock."
        let taskSyncLockFiles = try FileManager.default.contentsOfDirectory(
            at: context.storeURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(taskSyncLockPrefix) }
        #expect(taskSyncLockFiles.count == 1)
    }

    @Test("A personal task list clears its prior workspace after its pane moves")
    func movesPersonalTaskOwnerToTheCurrentWorkspace() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-personal-move")
        defer { context.cleanup() }
        let previousWorkspaceId = "31313131-3131-3131-3131-313131313131"
        let currentWorkspaceId = "32323232-3232-3232-3232-323232323232"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "moved-personal-session"
        let tasksRoot = context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        let taskDirectory = tasksRoot.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Moved task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let taskStoreIdentity = ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: previousWorkspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            claudeTaskDirectoryName: sessionId,
            claudeTaskStoreID: taskStoreIdentity.rawValue,
            markActive: true
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: currentWorkspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = currentWorkspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        let reconciliations = reconcileRequests(in: context)
        #expect(reconciliations.count == 2)
        let previousReconciliation = try #require(
            reconciliations.first { ($0["items"] as? [[String: Any]])?.isEmpty == true }
        )
        let currentReconciliation = try #require(
            reconciliations.first { ($0["items"] as? [[String: Any]])?.isEmpty != true }
        )
        let ownerID = taskOwnerID(directoryName: sessionId, tasksRootURL: tasksRoot)
        #expect(previousReconciliation["workspace_id"] as? String == previousWorkspaceId)
        #expect(previousReconciliation["owner_id"] as? String == ownerID)
        #expect((previousReconciliation["items"] as? [[String: Any]])?.isEmpty == true)
        #expect(currentReconciliation["workspace_id"] as? String == currentWorkspaceId)
        #expect(currentReconciliation["owner_id"] as? String == ownerID)
        #expect(
            (currentReconciliation["items"] as? [[String: Any]])?.compactMap {
                $0["text"] as? String
            } == ["Moved task"]
        )
        let persistedRecord = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            )
        )
        #expect(persistedRecord["workspaceId"] as? String == currentWorkspaceId)
        #expect(persistedRecord["surfaceId"] as? String == surfaceId)
    }

    @Test("A late task hook cannot resurrect a session consumed by SessionEnd")
    func rejectsTaskSyncAfterSessionEnd() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-after-session-end"
        )
        defer { context.cleanup() }
        let workspaceId = "38383838-3838-3838-3838-383838383838"
        let surfaceId = "39393939-3939-3939-3939-393939393939"
        let sessionId = "ended-task-session"
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Should not resurrect","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let initialResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        #expect(!initialResult.timedOut, Comment(rawValue: initialResult.stderr))
        #expect(initialResult.status == 0, Comment(rawValue: initialResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let reconciliationCountBeforeEnd = reconcileRequests(in: context).count

        let endResult = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"ended-task-session","hook_event_name":"SessionEnd","cwd":"/tmp"}"#
        )
        #expect(!endResult.timedOut, Comment(rawValue: endResult.stderr))
        #expect(endResult.status == 0, Comment(rawValue: endResult.stderr))
        #expect(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            ) == nil
        )

        let lateResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )
        #expect(!lateResult.timedOut, Comment(rawValue: lateResult.stderr))
        #expect(lateResult.status == 0, Comment(rawValue: lateResult.stderr))
        #expect(reconcileRequests(in: context).count == reconciliationCountBeforeEnd)
        #expect(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            ) == nil
        )
    }

    @Test("An unrecorded SessionEnd tombstones a first-sighting task hook")
    func tombstonesUnrecordedSessionBeforeTaskSync() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-unrecorded-session-end"
        )
        defer { context.cleanup() }
        let workspaceId = "3a3a3a3a-3a3a-3a3a-3a3a-3a3a3a3a3a3a"
        let surfaceId = "3b3b3b3b-3b3b-3b3b-3b3b-3b3b3b3b3b3b"
        let sessionId = "unrecorded-session-end"
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Must not resurrect","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        _ = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let endResult = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"unrecorded-session-end","hook_event_name":"SessionEnd"}"#
        )
        #expect(!endResult.timedOut, Comment(rawValue: endResult.stderr))
        #expect(endResult.status == 0, Comment(rawValue: endResult.stderr))

        let lateResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        #expect(!lateResult.timedOut, Comment(rawValue: lateResult.stderr))
        #expect(lateResult.status == 0, Comment(rawValue: lateResult.stderr))
        #expect(reconcileRequests(in: context).isEmpty)
        let state = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: context.storeURL)
            ) as? [String: Any]
        )
        #expect(
            (state["endedSessionIDs"] as? [String: Any])?[sessionId] != nil
        )
    }

    @Test("A personal task list clears its prior workspace after session teardown and resume")
    func movesPersonalTaskOwnerAfterSessionTeardown() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-personal-resume-move"
        )
        defer { context.cleanup() }
        let previousWorkspaceId = "34343434-3434-3434-3434-343434343434"
        let currentWorkspaceId = "35353535-3535-3535-3535-353535353535"
        let previousSurfaceId = "36363636-3636-3636-3636-363636363636"
        let currentSurfaceId = "37373737-3737-3737-3737-373737373737"
        let sessionId = "resumed-personal-session"
        let tasksRoot = context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        let taskDirectory = tasksRoot.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Resume task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: previousWorkspaceId,
            surfaceId: previousSurfaceId,
            workspaceIDsBySurface: [
                previousSurfaceId: previousWorkspaceId,
                currentSurfaceId: currentWorkspaceId,
            ]
        )
        var previousEnvironment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        previousEnvironment["CMUX_WORKSPACE_ID"] = previousWorkspaceId
        previousEnvironment["CMUX_SURFACE_ID"] = previousSurfaceId

        let firstResult = runHook(
            context: context,
            environment: previousEnvironment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        #expect(!firstResult.timedOut, Comment(rawValue: firstResult.stderr))
        #expect(firstResult.status == 0, Comment(rawValue: firstResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let teardownResult = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            environment: previousEnvironment,
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"SessionEnd","cwd":"\#(context.root.path)"}"#
        )
        #expect(!teardownResult.timedOut, Comment(rawValue: teardownResult.stderr))
        #expect(teardownResult.status == 0, Comment(rawValue: teardownResult.stderr))
        #expect(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            ) == nil
        )

        var currentEnvironment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        currentEnvironment["CMUX_WORKSPACE_ID"] = currentWorkspaceId
        currentEnvironment["CMUX_SURFACE_ID"] = currentSurfaceId

        // SessionEnd leaves a tombstone so a late task hook cannot resurrect
        // the consumed generation. A real resume starts a new generation
        // first; only that lifecycle boundary may re-admit the task hook.
        let resumeStartResult = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            environment: currentEnvironment,
            standardInput: #"{"session_id":"resumed-personal-session","hook_event_name":"SessionStart","source":"resume","cwd":"\#(context.root.path)"}"#
        )
        #expect(!resumeStartResult.timedOut, Comment(rawValue: resumeStartResult.stderr))
        #expect(resumeStartResult.status == 0, Comment(rawValue: resumeStartResult.stderr))

        try writeTask(
            #"{"id":"1","subject":"Resumed task","status":"in_progress"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let resumedResult = runHook(
            context: context,
            environment: currentEnvironment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )
        #expect(!resumedResult.timedOut, Comment(rawValue: resumedResult.stderr))
        #expect(resumedResult.status == 0, Comment(rawValue: resumedResult.stderr))

        let reconciliations = reconcileRequests(in: context)
        #expect(reconciliations.count == 3)
        let previousDelivery = try #require(reconciliations.first)
        let previousCleanup = try #require(
            reconciliations.dropFirst().first {
                ($0["items"] as? [[String: Any]])?.isEmpty == true
            }
        )
        let currentDelivery = try #require(
            reconciliations.dropFirst().first {
                ($0["items"] as? [[String: Any]])?.isEmpty != true
            }
        )
        let ownerID = taskOwnerID(directoryName: sessionId, tasksRootURL: tasksRoot)
        #expect(previousDelivery["workspace_id"] as? String == previousWorkspaceId)
        #expect(previousCleanup["workspace_id"] as? String == previousWorkspaceId)
        #expect(previousCleanup["owner_id"] as? String == ownerID)
        #expect((previousCleanup["items"] as? [[String: Any]])?.isEmpty == true)
        #expect(currentDelivery["workspace_id"] as? String == currentWorkspaceId)
        #expect(currentDelivery["owner_id"] as? String == ownerID)
        #expect(
            (currentDelivery["items"] as? [[String: Any]])?.compactMap {
                $0["text"] as? String
            } == ["Resumed task"]
        )
    }

    @Test("A rejected authoritative Feed snapshot prevents checklist commit")
    func rejectsChecklistWhenFeedSnapshotIsRejected() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-feed-rejection"
        )
        defer { context.cleanup() }
        let workspaceId = "38383838-3838-3838-3838-383838383838"
        let surfaceId = "39393939-3939-3939-3939-393939393939"
        let sessionId = "feed-rejection-session"
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Authoritative task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            feedPushSucceeds: false
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(reconcileRequests(in: context).isEmpty)
        #expect(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            ) == nil
        )
    }

    @Test("Namespaced delivery removes a legacy owner exactly once")
    func migratesLegacyChecklistOwnerBeforeDelivery() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-owner-migration")
        defer { context.cleanup() }
        let workspaceId = "13131313-1313-1313-1313-131313131313"
        let surfaceId = "14141414-1414-1414-1414-141414141414"
        let teammateWorkspaceId = "15151515-1515-1515-1515-151515151515"
        let teammateSurfaceId = "16161616-1616-1616-1616-161616161616"
        let sessionId = "legacy-owner-session"
        let teammateSessionId = "legacy-owner-teammate"
        let tasksRoot = context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        let taskDirectory = tasksRoot.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Migrated task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            claudeTaskDirectoryName: sessionId,
            markActive: true
        )
        try addLegacyTaskSessionRecord(
            to: context.storeURL,
            sourceSessionId: sessionId,
            sessionId: teammateSessionId,
            workspaceId: teammateWorkspaceId,
            surfaceId: teammateSurfaceId
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let firstResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskList"
        )

        #expect(!firstResult.timedOut, Comment(rawValue: firstResult.stderr))
        #expect(firstResult.status == 0, Comment(rawValue: firstResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let firstRequests = reconcileRequests(in: context)
        #expect(firstRequests.count == 3)
        let legacyRequests = firstRequests.prefix(2)
        #expect(Set(legacyRequests.compactMap { $0["workspace_id"] as? String }) == [
            workspaceId,
            teammateWorkspaceId,
        ])
        #expect(legacyRequests.allSatisfy {
            $0["owner_id"] as? String == "claude:\(sessionId)"
                && ($0["items"] as? [[String: Any]])?.isEmpty == true
        })
        let namespacedOwnerID = taskOwnerID(
            directoryName: sessionId,
            tasksRootURL: tasksRoot
        )
        #expect(firstRequests[2]["owner_id"] as? String == namespacedOwnerID)
        #expect((firstRequests[2]["items"] as? [[String: Any]])?.count == 1)
        let migratedRecord = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: sessionId
            )
        )
        #expect(
            migratedRecord["claudeTaskStoreID"] as? String
                == ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot).rawValue
        )
        let teammateRecord = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: teammateSessionId
            )
        )
        #expect(teammateRecord["claudeTaskStoreID"] == nil)
        #expect(teammateRecord["claudeTaskLegacyOwnerCleared"] as? Bool == true)

        let secondResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskList"
        )

        #expect(!secondResult.timedOut, Comment(rawValue: secondResult.stderr))
        #expect(secondResult.status == 0, Comment(rawValue: secondResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let allRequests = reconcileRequests(in: context)
        #expect(allRequests.count == 4)
        #expect(allRequests.last?["owner_id"] as? String == namespacedOwnerID)
    }

    @Test("TeamDelete clears session-only legacy owners from every workspace")
    func teamDeleteClearsLegacySessionDestinations() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-legacy-delete")
        defer { context.cleanup() }
        let workspaceId = "19191919-1919-1919-1919-191919191919"
        let surfaceId = "20202020-2020-2020-2020-202020202020"
        let teammateWorkspaceId = "21212121-2121-2121-2121-212121212121"
        let teammateSurfaceId = "22212121-2121-2121-2121-212121212121"
        let legacySessionId = "legacy-delete-leader"
        let teammateSessionId = "legacy-delete-teammate"
        let teamName = "Legacy-Deleted-Team"
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: legacySessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            claudeTaskDirectoryName: teamName,
            markActive: true
        )
        try addLegacyTaskSessionRecord(
            to: context.storeURL,
            sourceSessionId: legacySessionId,
            sessionId: teammateSessionId,
            workspaceId: teammateWorkspaceId,
            surfaceId: teammateSurfaceId
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: "replacement-delete-session",
            toolName: "TeamDelete",
            standardInput: #"{"session_id":"replacement-delete-session","hook_event_name":"PostToolUse","tool_name":"TeamDelete","tool_input":{"team_name":"Legacy-Deleted-Team"},"tool_response":{"success":true}}"#
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let requests = reconcileRequests(in: context)
        #expect(requests.count == 3)
        let legacyRequests = requests.prefix(2)
        #expect(Set(legacyRequests.compactMap { $0["workspace_id"] as? String }) == [
            workspaceId,
            teammateWorkspaceId,
        ])
        #expect(legacyRequests.allSatisfy {
            $0["owner_id"] as? String == "claude:\(teamName)"
                && ($0["items"] as? [[String: Any]])?.isEmpty == true
        })
        #expect(requests.last?["owner_id"] as? String == taskOwnerID(
            directoryName: teamName,
            tasksRootURL: context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        ))
        let legacyTaskStoreIdentity = ClaudeTaskStoreIdentity(
            tasksRootURL: context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        )
        let stateAfterDelete = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: context.storeURL)
            ) as? [String: Any]
        )
        let retiredAfterDelete = stateAfterDelete["retiredClaudeTaskLists"] as? [String: Any]
        #expect(
            retiredAfterDelete?["\(legacyTaskStoreIdentity.rawValue):\(teamName)"] != nil,
            "Legacy TeamDelete cleanup must still fence the current task-store identity"
        )
        for sessionId in [legacySessionId, teammateSessionId] {
            let record = try #require(
                try ClaudeHookLiveDeliveryHarness.sessionRecord(
                    in: context.storeURL,
                    sessionId: sessionId
                )
            )
            #expect(record["claudeTaskLegacyOwnerCleared"] as? Bool == true)
        }
    }

    @Test("Structured TeamDelete clears a legacy owner after session proof expires")
    func teamDeleteClearsLegacyOwnerWithoutSessionRecord() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-expired-delete")
        defer { context.cleanup() }
        let workspaceId = "25252525-2525-2525-2525-252525252525"
        let surfaceId = "26262626-2626-2626-2626-262626262626"
        let teamName = "Expired-Legacy-Team"
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: "expired-delete-session",
            toolName: "TeamDelete",
            standardInput: #"{"session_id":"expired-delete-session","hook_event_name":"PostToolUse","tool_name":"TeamDelete","tool_input":{"team_name":"Expired-Legacy-Team"},"tool_response":{"success":true}}"#
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let requests = reconcileRequests(in: context)
        #expect(requests.count == 2)
        #expect(requests[0]["owner_id"] as? String == "claude:\(teamName)")
        #expect((requests[0]["items"] as? [[String: Any]])?.isEmpty == true)
        #expect(requests[1]["owner_id"] as? String == taskOwnerID(
            directoryName: teamName,
            tasksRootURL: context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        ))
    }

    @Test("Snapshots over the checklist cap are sent whole for atomic rejection")
    func doesNotPublishTruncatedSnapshot() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-cap")
        defer { context.cleanup() }
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let surfaceId = "44444444-4444-4444-4444-444444444444"
        let sessionId = "task-sync-cap-session"
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
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
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
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
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
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
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
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
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let updatedItems = try #require(reconcileRequests(in: context).last?["items"] as? [[String: Any]])
        #expect(updatedItems.isEmpty)

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
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
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
        let teammateWorkspaceId = "17171717-1717-1717-1717-171717171717"
        let teammateSurfaceId = "18181818-1818-1818-1818-181818181818"
        let taskListID = "shared/task list"
        let taskDirectoryName = "shared-task-list"
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            workspaceIDsBySurface: [teammateSurfaceId: teammateWorkspaceId]
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
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        try writeTask(
            #"{"id":"1","subject":"Shared task","activeForm":"Updating shared task","status":"in_progress"}"#,
            named: "1.json",
            in: taskDirectory
        )
        var nestedEnvironment = environment
        nestedEnvironment["CMUX_AGENT_MANAGED_SUBAGENT"] = "1"
        nestedEnvironment["CMUX_WORKSPACE_ID"] = teammateWorkspaceId
        nestedEnvironment["CMUX_SURFACE_ID"] = teammateSurfaceId
        let teammateSessionId = "shared-list-teammate"
        let teammateResult = runHook(
            context: context,
            environment: nestedEnvironment,
            sessionId: teammateSessionId,
            toolName: "TaskUpdate"
        )
        #expect(!teammateResult.timedOut, Comment(rawValue: teammateResult.stderr))
        #expect(teammateResult.status == 0, Comment(rawValue: teammateResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

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
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let reconciliations = reconcileRequests(in: context)
        #expect(reconciliations.count == 5)
        let sharedOwnerID = taskOwnerID(
            directoryName: taskDirectoryName,
            tasksRootURL: taskDirectory.deletingLastPathComponent()
        )
        #expect(reconciliations.allSatisfy {
            $0["owner_id"] as? String == sharedOwnerID
        })
        let leaderItems = try #require(reconciliations.first?["items"] as? [[String: Any]])
        let teammateItems = try #require(reconciliations[1]["items"] as? [[String: Any]])
        let deletionItems = try #require(reconciliations.last?["items"] as? [[String: Any]])
        #expect(leaderItems.first?["id"] as? String == teammateItems.first?["id"] as? String)
        #expect(deletionItems.isEmpty)

        var teamDeleteEnvironment = environment
        teamDeleteEnvironment.removeValue(forKey: "CLAUDE_CODE_TASK_LIST_ID")
        let teamDeleteSessionId = "shared-list-team-delete"
        let teamDeleteResult = runHook(
            context: context,
            environment: teamDeleteEnvironment,
            sessionId: teamDeleteSessionId,
            toolName: "TeamDelete",
            standardInput: #"{"session_id":"shared-list-team-delete","hook_event_name":"PostToolUse","tool_name":"TeamDelete","tool_input":{"team_name":"shared/task list"},"tool_response":{"success":true}}"#
        )
        #expect(!teamDeleteResult.timedOut, Comment(rawValue: teamDeleteResult.stderr))
        #expect(teamDeleteResult.status == 0, Comment(rawValue: teamDeleteResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let teamDeleteRequests = reconcileRequests(in: context).suffix(2)
        #expect(Set(teamDeleteRequests.compactMap { $0["workspace_id"] as? String }) == [
            workspaceId,
            teammateWorkspaceId,
        ])
        #expect(teamDeleteRequests.allSatisfy {
            $0["owner_id"] as? String == sharedOwnerID
                && ($0["items"] as? [[String: Any]])?.isEmpty == true
        })
        #expect(try taskListDestinationRecords(in: context.storeURL).isEmpty)
        let taskStoreIdentity = ClaudeTaskStoreIdentity(
            tasksRootURL: taskDirectory.deletingLastPathComponent()
        )
        let stateAfterDelete = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: context.storeURL)
            ) as? [String: Any]
        )
        let retiredAfterDelete = stateAfterDelete["retiredClaudeTaskLists"] as? [String: Any]
        #expect(
            retiredAfterDelete?["\(taskStoreIdentity.rawValue):\(taskDirectoryName)"] != nil,
            "A successful TeamDelete must leave a retirement fence for delayed hooks"
        )
        let reconciliationCountBeforeDelayedHook = reconcileRequests(in: context).count
        let delayedHookResult = runHook(
            context: context,
            environment: environment,
            sessionId: leaderSessionId,
            toolName: "TaskUpdate"
        )
        #expect(!delayedHookResult.timedOut, Comment(rawValue: delayedHookResult.stderr))
        #expect(delayedHookResult.status == 0, Comment(rawValue: delayedHookResult.stderr))
        #expect(
            reconcileRequests(in: context).count == reconciliationCountBeforeDelayedHook,
            "A delayed task hook must not re-admit the retired task-list owner"
        )

        let feedSessionIds = context.state.snapshot().compactMap(feedEvent)
            .compactMap { $0["session_id"] as? String }
        #expect(feedSessionIds == [
            "claude-\(leaderSessionId)",
            "claude-\(teammateSessionId)",
            "claude-\(deletionSessionId)",
            "claude-\(teamDeleteSessionId)",
        ])
        let leaderRecord = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: leaderSessionId
            )
        )
        #expect(leaderRecord["claudeTaskDirectoryName"] == nil)
    }

    @Test("A delayed configured-list hook cannot re-admit a retired owner")
    func rejectsDelayedConfiguredTaskListAfterRetirement() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-retired-configured"
        )
        defer { context.cleanup() }
        let workspaceId = "abababab-abab-abab-abab-abababababab"
        let surfaceId = "acacacac-acac-acac-acac-acacacacacac"
        let sessionId = "retired-configured-session"
        let taskListID = "retired-configured-list"
        let tasksRoot = context.root.appendingPathComponent(
            ".claude/tasks",
            isDirectory: true
        )
        let taskDirectory = tasksRoot.appendingPathComponent(
            taskListID,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Retained task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CLAUDE_CODE_TASK_LIST_ID"] = taskListID

        let initialResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        #expect(!initialResult.timedOut, Comment(rawValue: initialResult.stderr))
        #expect(initialResult.status == 0, Comment(rawValue: initialResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let taskStoreIdentity = ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
        try retireTaskList(
            taskListID: taskListID,
            taskStoreIdentity: taskStoreIdentity,
            retiredAt: Date().timeIntervalSince1970 + 1,
            storeURL: context.storeURL
        )
        let requestCountBeforeDelayedHook = reconcileRequests(in: context).count
        let delayedResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )

        #expect(!delayedResult.timedOut, Comment(rawValue: delayedResult.stderr))
        #expect(delayedResult.status == 0, Comment(rawValue: delayedResult.stderr))
        #expect(reconcileRequests(in: context).count == requestCountBeforeDelayedHook)
        let state = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: context.storeURL)
            ) as? [String: Any]
        )
        let retired = state["retiredClaudeTaskLists"] as? [String: Any]
        #expect(retired?["\(taskStoreIdentity.rawValue):\(taskListID)"] != nil)
    }

    @Test("A new SessionStart generation cannot reuse a prior task-directory proof")
    func rejectsPriorTaskDirectoryAfterSessionGenerationReset() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-generation-fence"
        )
        defer { context.cleanup() }
        let workspaceId = "adadadad-adad-adad-adad-adadadadadad"
        let surfaceId = "aeaeaeae-aeae-aeae-aeae-aeaeaeaeaeae"
        let sessionId = "generation-fence-session"
        let taskListID = "prior-shared-list"
        let tasksRoot = context.root.appendingPathComponent(
            ".claude/tasks",
            isDirectory: true
        )
        let taskDirectory = tasksRoot.appendingPathComponent(
            taskListID,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Prior generation task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var configuredEnvironment = ClaudeHookLiveDeliveryHarness.hookEnvironment(
            context: context
        )
        configuredEnvironment["CMUX_WORKSPACE_ID"] = workspaceId
        configuredEnvironment["CMUX_SURFACE_ID"] = surfaceId
        configuredEnvironment["CLAUDE_CODE_TASK_LIST_ID"] = taskListID

        let initialResult = runHook(
            context: context,
            environment: configuredEnvironment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        #expect(!initialResult.timedOut, Comment(rawValue: initialResult.stderr))
        #expect(initialResult.status == 0, Comment(rawValue: initialResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        var newGenerationEnvironment = configuredEnvironment
        newGenerationEnvironment.removeValue(forKey: "CLAUDE_CODE_TASK_LIST_ID")
        let sessionStartResult = ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            environment: newGenerationEnvironment,
            standardInput: #"{"session_id":"generation-fence-session","source":"clear","hook_event_name":"SessionStart"}"#
        )
        #expect(!sessionStartResult.timedOut, Comment(rawValue: sessionStartResult.stderr))
        #expect(sessionStartResult.status == 0, Comment(rawValue: sessionStartResult.stderr))

        let requestCountBeforeLateHook = reconcileRequests(in: context).count
        let lateResult = runHook(
            context: context,
            environment: newGenerationEnvironment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )
        #expect(!lateResult.timedOut, Comment(rawValue: lateResult.stderr))
        #expect(lateResult.status == 0, Comment(rawValue: lateResult.stderr))
        #expect(reconcileRequests(in: context).count == requestCountBeforeLateHook)
    }

    @Test("Configured-list capacity clears the oldest owner before admission")
    func retiresOldestConfiguredTaskDestinationAtCapacity() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-list-capacity")
        defer { context.cleanup() }
        let workspaceId = "23232323-2323-2323-2323-232323232323"
        let surfaceId = "24242424-2424-2424-2424-242424242424"
        let sessionId = "configured-capacity-session"
        let taskListID = "NewestList"
        let tasksRoot = context.root.appendingPathComponent(".claude/tasks", isDirectory: true)
        let taskDirectory = tasksRoot.appendingPathComponent(taskListID, isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Newest configured task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        try ClaudeHookLiveDeliveryHarness.writeSessionStore(
            to: context.storeURL,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: context.root.path,
            markActive: true
        )
        let taskStoreIdentity = ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
        try seedConfiguredTaskDestinations(
            count: 128,
            taskStoreIdentity: taskStoreIdentity,
            workspaceId: workspaceId,
            storeURL: context.storeURL
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CLAUDE_CODE_TASK_LIST_ID"] = taskListID

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskList"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let requests = reconcileRequests(in: context)
        #expect(requests.count == 2)
        let archivedRequest = try #require(
            requests.first {
                $0["owner_id"] as? String == taskOwnerID(
                    directoryName: "ArchivedList0",
                    tasksRootURL: tasksRoot
                )
            }
        )
        #expect((archivedRequest["items"] as? [[String: Any]])?.isEmpty == true)
        #expect(
            requests.contains {
                $0["owner_id"] as? String == taskOwnerID(
                    directoryName: taskListID,
                    tasksRootURL: tasksRoot
                )
            }
        )
        let records = try taskListDestinationRecords(in: context.storeURL)
        #expect(records.count == 128)
        #expect(!records.values.contains {
            $0["taskListID"] as? String == "ArchivedList0"
        })
        #expect(records.values.contains {
            $0["taskListID"] as? String == taskListID
        })
    }

    @Test("Automatic team cleanup does not consume the first personal task hook")
    func transitionsFromAutomaticTeamToPersonalTasksInOneHook() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-auto-team")
        defer { context.cleanup() }
        let workspaceId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let surfaceId = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let teammateWorkspaceId = "12121212-1212-1212-1212-121212121212"
        let teammateSurfaceId = "34343434-3434-3434-3434-343434343434"
        let leaderSessionId = "automatic-team-leader"
        let teammateSessionId = "automatic-team-teammate"
        let leaderAgentId = "agent-leader"
        let teammateAgentId = "agent-teammate"
        let teamName = "Session_Automatic_Team"
        let teamDirectoryName = "session-automatic-team"
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            workspaceIDsBySurface: [teammateSurfaceId: teammateWorkspaceId],
            rejectsEmptyFeedSnapshots: true
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
            .appendingPathComponent(".claude/teams/\(teamDirectoryName)", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try Data(
            #"{"name":"\#(teamName)","leadAgentId":"\#(leaderAgentId)","leadSessionId":"\#(leaderSessionId)","members":[{"agentId":"\#(leaderAgentId)"},{"agentId":"\#(teammateAgentId)"}]}"#.utf8
        ).write(to: teamDirectory.appendingPathComponent("config.json"))

        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = teammateWorkspaceId
        environment["CMUX_SURFACE_ID"] = teammateSurfaceId
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
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let reconciliation = try #require(reconcileRequests(in: context).last)
        #expect(reconciliation["workspace_id"] as? String == teammateWorkspaceId)
        let teamOwnerID = taskOwnerID(
            directoryName: teamName,
            tasksRootURL: taskDirectory.deletingLastPathComponent()
        )
        #expect(reconciliation["owner_id"] as? String == teamOwnerID)
        let items = try #require(reconciliation["items"] as? [[String: Any]])
        #expect(items.compactMap { $0["text"] as? String } == ["Claiming shared task"])

        var leaderEnvironment = environment
        leaderEnvironment["CMUX_WORKSPACE_ID"] = workspaceId
        leaderEnvironment["CMUX_SURFACE_ID"] = surfaceId
        leaderEnvironment.removeValue(forKey: "CMUX_AGENT_MANAGED_SUBAGENT")
        let personalTaskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(leaderSessionId)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: personalTaskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Stale personal task","status":"pending"}"#,
            named: "1.json",
            in: personalTaskDirectory
        )
        let leaderTeamResult = runHook(
            context: context,
            environment: leaderEnvironment,
            sessionId: leaderSessionId,
            toolName: "TaskList"
        )

        #expect(!leaderTeamResult.timedOut, Comment(rawValue: leaderTeamResult.stderr))
        #expect(leaderTeamResult.status == 0, Comment(rawValue: leaderTeamResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let sharedDestinations = Array(reconcileRequests(in: context).suffix(2))
        #expect(Set(sharedDestinations.compactMap { $0["workspace_id"] as? String }) == [
            workspaceId,
            teammateWorkspaceId,
        ])
        #expect(sharedDestinations.allSatisfy {
            $0["owner_id"] as? String == teamOwnerID
        })

        try FileManager.default.removeItem(at: teamDirectory)
        try FileManager.default.removeItem(at: taskDirectory)
        try setTeamBindingUpdatedAt(
            0,
            taskListID: teamName,
            storeURL: context.storeURL
        )
        try writeTask(
            #"{"id":"1","subject":"Personal follow-up","status":"pending"}"#,
            named: "1.json",
            in: personalTaskDirectory
        )
        let personalResult = runHook(
            context: context,
            environment: leaderEnvironment,
            sessionId: leaderSessionId,
            toolName: "TaskCreate",
            standardInput: #"{"session_id":"\#(leaderSessionId)","hook_event_name":"PostToolUse","tool_name":"TaskCreate","tool_input":{"subject":"Personal follow-up"},"tool_response":{"task":{"id":"1","subject":"Personal follow-up"}}}"#
        )

        #expect(!personalResult.timedOut, Comment(rawValue: personalResult.stderr))
        #expect(personalResult.status == 0, Comment(rawValue: personalResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let transitionReconciliations = Array(reconcileRequests(in: context).suffix(3))
        #expect(transitionReconciliations.count == 3)
        let cleanupReconciliations = transitionReconciliations.filter {
            $0["owner_id"] as? String == teamOwnerID
        }
        #expect(cleanupReconciliations.count == 2)
        #expect(Set(cleanupReconciliations.compactMap { $0["workspace_id"] as? String }) == [
            workspaceId,
            teammateWorkspaceId,
        ])
        #expect(cleanupReconciliations.allSatisfy { reconciliation in
            reconciliation["owner_id"] as? String == teamOwnerID
                && (reconciliation["items"] as? [[String: Any]])?.isEmpty == true
        })

        let personalReconciliation = try #require(
            transitionReconciliations.first {
                $0["owner_id"] as? String != teamOwnerID
            }
        )
        #expect(personalReconciliation["workspace_id"] as? String == workspaceId)
        #expect(personalReconciliation["owner_id"] as? String == taskOwnerID(
            directoryName: leaderSessionId,
            tasksRootURL: personalTaskDirectory.deletingLastPathComponent()
        ))
        let personalItems = try #require(personalReconciliation["items"] as? [[String: Any]])
        #expect(personalItems.compactMap { $0["text"] as? String } == ["Personal follow-up"])
    }

    @Test("An all-completed snapshot preserves Feed history and clears workspace-owned todos")
    func clearsWorkspaceOwnerForAllCompletedSnapshot() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-completed")
        defer { context.cleanup() }
        let workspaceId = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        let surfaceId = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        let sessionId = "completed-list-session"
        let taskListID = "completed-list"
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
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
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
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

    @Test("An all-completed personal list retires its durable destination proof")
    func retiresCompletedPersonalTaskDestinations() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-completed-personal"
        )
        defer { context.cleanup() }
        let workspaceId = "dededede-dede-dede-dede-dededededede"
        let surfaceId = "efefefef-efef-efef-efef-efefefefefef"
        let sessionId = "completed-personal-session"
        let taskDirectory = context.root.appendingPathComponent(
            ".claude/tasks/\(sessionId)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Personal task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let pendingResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskCreate"
        )
        #expect(!pendingResult.timedOut, Comment(rawValue: pendingResult.stderr))
        #expect(pendingResult.status == 0, Comment(rawValue: pendingResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(try taskListDestinationRecords(in: context.storeURL).count == 1)

        try writeTask(
            #"{"id":"1","subject":"Personal task","status":"completed"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let completedResult = runHook(
            context: context,
            environment: environment,
            sessionId: sessionId,
            toolName: "TaskUpdate"
        )

        #expect(!completedResult.timedOut, Comment(rawValue: completedResult.stderr))
        #expect(completedResult.status == 0, Comment(rawValue: completedResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(try taskListDestinationRecords(in: context.storeURL).isEmpty)
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

    private func setTeamBindingUpdatedAt(
        _ updatedAt: TimeInterval,
        taskListID: String,
        storeURL: URL
    ) throws {
        let data = try Data(contentsOf: storeURL)
        var state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var bindings = try #require(
            state["claudeTeamTaskBindings"] as? [String: [String: Any]]
        )
        let bindingEntry = try #require(bindings.first { _, record in
            let binding = record["binding"] as? [String: Any]
            return binding?["taskListID"] as? String == taskListID
        })
        var record = bindingEntry.value
        record["updatedAt"] = updatedAt
        bindings[bindingEntry.key] = record
        state["claudeTeamTaskBindings"] = bindings
        let updatedData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: storeURL)
    }

    private func addLegacyTaskSessionRecord(
        to storeURL: URL,
        sourceSessionId: String,
        sessionId: String,
        workspaceId: String,
        surfaceId: String
    ) throws {
        let data = try Data(contentsOf: storeURL)
        var state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var sessions = try #require(state["sessions"] as? [String: [String: Any]])
        var record = try #require(sessions[sourceSessionId])
        record["sessionId"] = sessionId
        record["workspaceId"] = workspaceId
        record["surfaceId"] = surfaceId
        sessions[sessionId] = record
        state["sessions"] = sessions
        let updatedData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: storeURL)
    }

    private func taskOwnerID(
        directoryName: String,
        tasksRootURL: URL
    ) -> String {
        let taskStoreIdentity = ClaudeTaskStoreIdentity(
            tasksRootURL: tasksRootURL
        )
        return "claude:\(taskStoreIdentity.rawValue):\(directoryName)"
    }

    private func taskListDestinationRecords(
        in storeURL: URL
    ) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: storeURL)
        let state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return state["claudeTaskListDestinations"] as? [String: [String: Any]] ?? [:]
    }

    private func retireTaskList(
        taskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        retiredAt: TimeInterval,
        storeURL: URL
    ) throws {
        let data = try Data(contentsOf: storeURL)
        var state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var retired = state["retiredClaudeTaskLists"] as? [String: TimeInterval] ?? [:]
        retired["\(taskStoreIdentity.rawValue):\(taskListID)"] = retiredAt
        state["retiredClaudeTaskLists"] = retired
        let updatedData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: storeURL)
    }

    private func seedConfiguredTaskDestinations(
        count: Int,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        workspaceId: String,
        storeURL: URL
    ) throws {
        let data = try Data(contentsOf: storeURL)
        var state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var records: [String: [String: Any]] = [:]
        for index in 0..<count {
            let taskListID = "ArchivedList\(index)"
            records["\(taskStoreIdentity.rawValue):\(taskListID)"] = [
                "taskStoreIdentity": ["rawValue": taskStoreIdentity.rawValue],
                "taskListID": taskListID,
                "workspaceIDs": [workspaceId],
                "updatedAt": TimeInterval(index),
            ]
        }
        state["claudeTaskListDestinations"] = records
        let updatedData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: storeURL)
    }

    private func reconcileRequests(in context: ClaudeHookLiveDeliveryHarness.Context) -> [[String: Any]] {
        ClaudeHookLiveDeliveryHarness.taskSyncReconcileRequests(in: context)
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
