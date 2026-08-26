import CMUXAgentLaunch
import Foundation
import Testing

@Suite("Claude automatic-team task sync", .serialized)
struct ClaudeAutomaticTeamTaskSyncHookTests {
    @Test("Same-named teams in independent Claude profiles keep distinct owners")
    func isolatesTaskStoresWithTheSameTeamName() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-profiles")
        defer { context.cleanup() }
        let firstWorkspaceId = "01010101-0101-0101-0101-010101010101"
        let firstSurfaceId = "02020202-0202-0202-0202-020202020202"
        let secondWorkspaceId = "03030303-0303-0303-0303-030303030303"
        let secondSurfaceId = "04040404-0404-0404-0404-040404040404"
        let teamName = "Shared_Profile_Team"
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: firstWorkspaceId,
            surfaceId: firstSurfaceId,
            workspaceIDsBySurface: [secondSurfaceId: secondWorkspaceId]
        )

        var expectedOwnerIDs: [String] = []
        var expectedItemIDs: [String] = []
        for profile in [
            ("profile-a", "leader-a", "agent-a", firstWorkspaceId, firstSurfaceId),
            ("profile-b", "leader-b", "agent-b", secondWorkspaceId, secondSurfaceId),
        ] {
            let configRoot = context.root.appendingPathComponent(
                profile.0,
                isDirectory: true
            )
            let teamDirectory = configRoot.appendingPathComponent(
                "teams/shared-profile-team",
                isDirectory: true
            )
            let tasksRoot = configRoot.appendingPathComponent("tasks", isDirectory: true)
            let taskDirectory = tasksRoot.appendingPathComponent(
                teamName,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: teamDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: taskDirectory,
                withIntermediateDirectories: true
            )
            try writeTeamConfig(
                name: teamName,
                leaderSessionID: profile.1,
                agentID: profile.2,
                to: teamDirectory
            )
            try writeTask(
                #"{"id":"1","subject":"Task for \#(profile.0)","status":"pending"}"#,
                to: taskDirectory
            )
            var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(
                context: context
            )
            environment["CLAUDE_CONFIG_DIR"] = configRoot.path
            environment["CMUX_WORKSPACE_ID"] = profile.3
            environment["CMUX_SURFACE_ID"] = profile.4

            let result = runHook(
                context: context,
                environment: environment,
                sessionId: "session-\(profile.0)",
                agentID: profile.2
            )

            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
            #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
            let delivery = try #require(reconcileRequests(in: context).last)
            expectedOwnerIDs.append(taskOwnerID(
                directoryName: teamName,
                tasksRootURL: tasksRoot
            ))
            #expect(delivery["owner_id"] as? String == expectedOwnerIDs.last)
            let items = try #require(delivery["items"] as? [[String: Any]])
            expectedItemIDs.append(try #require(items.first?["id"] as? String))
        }

        let reconciliations = reconcileRequests(in: context)
        #expect(reconciliations.count == 2)
        #expect(Set(expectedOwnerIDs).count == 2)
        #expect(Set(expectedItemIDs).count == 2)
        #expect(try teamBindingRecords(in: context.storeURL).count == 2)
    }

    @Test("Authoritative team membership wins over a stale personal task collision")
    func rejectsStalePersonalTaskCollisionForTeamLeader() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-team-collision")
        defer { context.cleanup() }
        let workspaceId = "05050505-0505-0505-0505-050505050505"
        let surfaceId = "06060606-0606-0606-0606-060606060606"
        let sessionId = "team-leader-session"
        let personalTaskDirectory = context.root.appendingPathComponent(
            ".claude/tasks/\(sessionId)",
            isDirectory: true
        )
        let teamName = "Authoritative_Team"
        let teamTaskDirectory = context.root.appendingPathComponent(
            ".claude/tasks/\(teamName)",
            isDirectory: true
        )
        let teamDirectory = context.root.appendingPathComponent(
            ".claude/teams/authoritative-team",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: personalTaskDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: teamTaskDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: teamDirectory,
            withIntermediateDirectories: true
        )
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: sessionId,
            agentID: "team-leader-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Colliding task","activeForm":"Stale personal copy","status":"in_progress"}"#,
            to: personalTaskDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Colliding task","activeForm":"Authoritative team copy","status":"in_progress"}"#,
            to: teamTaskDirectory
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
            sessionId: sessionId,
            toolName: "TaskCreate",
            standardInput: #"{"session_id":"\#(sessionId)","hook_event_name":"PostToolUse","tool_name":"TaskCreate","tool_input":{"subject":"Colliding task"},"tool_response":{"task":{"id":"1","subject":"Colliding task"}}}"#
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let items = try #require(
            reconcileRequests(in: context).last?["items"] as? [[String: Any]]
        )
        #expect(items.compactMap { $0["text"] as? String } == ["Authoritative team copy"])
    }

    @Test("A reused team name clears the former owner without inheriting its workspaces")
    func clearsFormerTeamBeforeReusingTaskListID() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-reused-team")
        defer { context.cleanup() }
        let formerWorkspaceId = "45454545-4545-4545-4545-454545454545"
        let formerSurfaceId = "56565656-5656-5656-5656-565656565656"
        let currentWorkspaceId = "67676767-6767-6767-6767-676767676767"
        let currentSurfaceId = "78787878-7878-7878-7878-787878787878"
        let teamName = "Reused_Team"
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/reused-team", isDirectory: true)
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(teamName)", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: formerWorkspaceId,
            surfaceId: formerSurfaceId,
            workspaceIDsBySurface: [currentSurfaceId: currentWorkspaceId]
        )

        try writeTeamConfig(
            name: teamName,
            leaderSessionID: "former-leader",
            agentID: "former-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Former team task","status":"pending"}"#,
            to: taskDirectory
        )
        var formerEnvironment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        formerEnvironment["CMUX_WORKSPACE_ID"] = formerWorkspaceId
        formerEnvironment["CMUX_SURFACE_ID"] = formerSurfaceId
        let formerResult = runHook(
            context: context,
            environment: formerEnvironment,
            sessionId: "former-session",
            agentID: "former-agent"
        )

        #expect(!formerResult.timedOut, Comment(rawValue: formerResult.stderr))
        #expect(formerResult.status == 0, Comment(rawValue: formerResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        try writeTeamConfig(
            name: teamName,
            leaderSessionID: "current-leader",
            agentID: "current-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Current team task","status":"pending"}"#,
            to: taskDirectory
        )
        var currentEnvironment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        currentEnvironment["CMUX_WORKSPACE_ID"] = currentWorkspaceId
        currentEnvironment["CMUX_SURFACE_ID"] = currentSurfaceId
        let currentResult = runHook(
            context: context,
            environment: currentEnvironment,
            sessionId: "current-session",
            agentID: "current-agent"
        )

        #expect(!currentResult.timedOut, Comment(rawValue: currentResult.stderr))
        #expect(currentResult.status == 0, Comment(rawValue: currentResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        let reconciliations = reconcileRequests(in: context)
        #expect(reconciliations.count == 3)
        let formerClear = reconciliations[1]
        #expect(formerClear["workspace_id"] as? String == formerWorkspaceId)
        let teamOwnerID = taskOwnerID(
            directoryName: teamName,
            tasksRootURL: taskDirectory.deletingLastPathComponent()
        )
        #expect(formerClear["owner_id"] as? String == teamOwnerID)
        #expect((formerClear["items"] as? [[String: Any]])?.isEmpty == true)

        let currentDelivery = reconciliations[2]
        #expect(currentDelivery["workspace_id"] as? String == currentWorkspaceId)
        #expect(currentDelivery["owner_id"] as? String == teamOwnerID)
        let currentItems = try #require(currentDelivery["items"] as? [[String: Any]])
        #expect(currentItems.compactMap { $0["text"] as? String } == ["Current team task"])
    }

    @Test("Leaderless team membership edits retain completed destinations")
    func retainsCompletedTeamWorkspaceHistory() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-complete-team")
        defer { context.cleanup() }
        let firstWorkspaceId = "89898989-8989-8989-8989-898989898989"
        let firstSurfaceId = "90909090-9090-9090-9090-909090909090"
        let secondWorkspaceId = "93939393-9393-9393-9393-939393939393"
        let secondSurfaceId = "94949494-9494-9494-9494-949494949494"
        let teamName = "Completed_Team"
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/completed-team", isDirectory: true)
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(teamName)", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: nil,
            agentID: "completed-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Finished","status":"completed"}"#,
            to: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: firstWorkspaceId,
            surfaceId: firstSurfaceId,
            workspaceIDsBySurface: [secondSurfaceId: secondWorkspaceId]
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = firstWorkspaceId
        environment["CMUX_SURFACE_ID"] = firstSurfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: "completed-session",
            agentID: "completed-agent"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let items = try #require(
            reconcileRequests(in: context).last?["items"] as? [[String: Any]]
        )
        #expect(items.isEmpty)
        let completedBinding = try #require(
            try teamBindingRecords(in: context.storeURL).values.first
        )
        #expect(completedBinding["workspaceIDs"] as? [String] == [firstWorkspaceId])

        try writeTask(
            #"{"id":"1","subject":"Reopened","status":"pending"}"#,
            to: taskDirectory
        )
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: nil,
            agentID: "completed-agent",
            additionalAgentIDs: ["new-member"],
            to: teamDirectory
        )
        environment["CMUX_WORKSPACE_ID"] = secondWorkspaceId
        environment["CMUX_SURFACE_ID"] = secondSurfaceId
        let reopenedResult = runHook(
            context: context,
            environment: environment,
            sessionId: "completed-session",
            agentID: "completed-agent"
        )

        #expect(!reopenedResult.timedOut, Comment(rawValue: reopenedResult.stderr))
        #expect(reopenedResult.status == 0, Comment(rawValue: reopenedResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let reopenedDeliveries = reconcileRequests(in: context).suffix(2)
        #expect(Set(reopenedDeliveries.compactMap { $0["workspace_id"] as? String }) == [
            firstWorkspaceId,
            secondWorkspaceId,
        ])
        #expect(reopenedDeliveries.allSatisfy { delivery in
            let items = delivery["items"] as? [[String: Any]]
            return items?.compactMap { $0["text"] as? String } == ["Reopened"]
        })
        let reopenedBinding = try #require(
            try teamBindingRecords(in: context.storeURL).values.first
        )
        #expect(reopenedBinding["workspaceIDs"] as? [String] == [
            firstWorkspaceId,
            secondWorkspaceId,
        ])
    }

    @Test("TeamDelete clears the configured owner after identity changes")
    func clearsTeamOwnerOnTeamDelete() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-team-delete")
        defer { context.cleanup() }
        let workspaceId = "95959595-9595-9595-9595-959595959595"
        let surfaceId = "96969696-9696-9696-9696-969696969696"
        let secondWorkspaceId = "95959595-9595-9595-9595-959595959596"
        let secondSurfaceId = "96969696-9696-9696-9696-969696969697"
        let teamName = "Deleted-Team"
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/deleted-team", isDirectory: true)
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(teamName)", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: "deleted-leader",
            agentID: "deleted-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Pending at deletion","status":"pending"}"#,
            to: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            workspaceIDsBySurface: [secondSurfaceId: secondWorkspaceId]
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let initialResult = runHook(
            context: context,
            environment: environment,
            sessionId: "deleted-session",
            agentID: "deleted-agent"
        )
        #expect(!initialResult.timedOut, Comment(rawValue: initialResult.stderr))
        #expect(initialResult.status == 0, Comment(rawValue: initialResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(try teamBindingRecords(in: context.storeURL).count == 1)

        environment["CMUX_WORKSPACE_ID"] = secondWorkspaceId
        environment["CMUX_SURFACE_ID"] = secondSurfaceId
        let secondWorkspaceResult = runHook(
            context: context,
            environment: environment,
            sessionId: "deleted-session",
            agentID: "deleted-agent"
        )
        #expect(!secondWorkspaceResult.timedOut, Comment(rawValue: secondWorkspaceResult.stderr))
        #expect(secondWorkspaceResult.status == 0, Comment(rawValue: secondWorkspaceResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        // Simulate a durable proof written before task-store namespaces existed.
        try rewriteTeamBindingAsLegacy(
            taskListID: teamName,
            storeURL: context.storeURL
        )

        let deleteResult = runHook(
            context: context,
            environment: environment,
            sessionId: "replacement-session",
            agentID: "replacement-agent",
            toolName: "TeamDelete",
            standardInput: #"{"session_id":"replacement-session","hook_event_name":"PostToolUse","agent_id":"replacement-agent","tool_name":"TeamDelete","tool_input":{"team_name":"Deleted-Team"},"tool_response":{"success":true}}"#
        )

        #expect(!deleteResult.timedOut, Comment(rawValue: deleteResult.stderr))
        #expect(deleteResult.status == 0, Comment(rawValue: deleteResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let deletedDeliveries = reconcileRequests(in: context).suffix(2)
        #expect(Set(deletedDeliveries.compactMap { $0["workspace_id"] as? String }) == [
            workspaceId,
            secondWorkspaceId,
        ])
        #expect(deletedDeliveries.allSatisfy {
            $0["owner_id"] as? String == "claude:\(teamName)"
                && ($0["items"] as? [[String: Any]])?.isEmpty == true
        })
        #expect(try teamBindingRecords(in: context.storeURL).isEmpty)
        let deletedSessionRecord = try #require(
            try ClaudeHookLiveDeliveryHarness.sessionRecord(
                in: context.storeURL,
                sessionId: "deleted-session"
            )
        )
        #expect(deletedSessionRecord["claudeTaskDirectoryName"] == nil)
        #expect(deletedSessionRecord["claudeTaskStoreID"] == nil)
        #expect(FileManager.default.fileExists(
            atPath: taskDirectory.appendingPathComponent("1.json").path
        ))
    }

    @Test("A missing team config clears retained rows even when task files remain")
    func clearsRetainedOwnerAfterTeamConfigDisappears() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-orphaned-team")
        defer { context.cleanup() }
        let workspaceId = "91959595-9595-9595-9595-959595959595"
        let surfaceId = "92969696-9696-9696-9696-969696969696"
        let teamName = "Orphaned_Team"
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/orphaned-team", isDirectory: true)
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(teamName)", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: "orphaned-leader",
            agentID: "orphaned-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Orphaned task","status":"pending"}"#,
            to: taskDirectory
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
            sessionId: "orphaned-session",
            agentID: "orphaned-agent"
        )
        #expect(!initialResult.timedOut, Comment(rawValue: initialResult.stderr))
        #expect(initialResult.status == 0, Comment(rawValue: initialResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(try teamBindingRecords(in: context.storeURL).count == 1)

        try FileManager.default.removeItem(
            at: teamDirectory.appendingPathComponent("config.json")
        )
        let cleanupResult = runHook(
            context: context,
            environment: environment,
            sessionId: "orphaned-session",
            agentID: "orphaned-agent"
        )

        #expect(!cleanupResult.timedOut, Comment(rawValue: cleanupResult.stderr))
        #expect(cleanupResult.status == 0, Comment(rawValue: cleanupResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let cleanupItems = try #require(
            reconcileRequests(in: context).last?["items"] as? [[String: Any]]
        )
        #expect(cleanupItems.isEmpty)
        #expect(try teamBindingRecords(in: context.storeURL).isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: taskDirectory.appendingPathComponent("1.json").path
        ))

        let reconciliationCountAfterCleanup = reconcileRequests(in: context).count
        let lateResult = runHook(
            context: context,
            environment: environment,
            sessionId: "late-personal-session",
            toolName: "TaskUpdate",
            standardInput: #"{"session_id":"late-personal-session","hook_event_name":"PostToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"1","status":"in_progress"},"tool_response":{"task":{"id":"1","subject":"Orphaned task"}}}"#
        )
        #expect(!lateResult.timedOut, Comment(rawValue: lateResult.stderr))
        #expect(lateResult.status == 0, Comment(rawValue: lateResult.stderr))
        #expect(reconcileRequests(in: context).count == reconciliationCountAfterCleanup)
    }

    @Test("Closed workspaces are retired from a durable team binding")
    func retiresClosedWorkspaceDestination() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-closed-workspace")
        defer { context.cleanup() }
        let closedWorkspaceId = "97979797-9797-9797-9797-979797979797"
        let currentWorkspaceId = "98989898-9898-9898-9898-989898989898"
        let currentSurfaceId = "99999999-9898-9898-9898-989898989898"
        let teamName = "Available_Team"
        let tasksRoot = context.root.appendingPathComponent(
            ".claude/tasks",
            isDirectory: true
        )
        let taskStoreIdentity = ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
        let bindingKey = "\(taskStoreIdentity.rawValue):\(teamName)"
        let state: [String: Any] = [
            "version": 1,
            "sessions": [:],
            "claudeTeamTaskBindings": [
                bindingKey: [
                    "binding": [
                        "taskStoreIdentity": ["rawValue": taskStoreIdentity.rawValue],
                        "taskListID": teamName,
                        "leaderSessionID": "available-leader",
                        "agentIDs": ["available-agent"],
                    ],
                    "workspaceIDs": [closedWorkspaceId, currentWorkspaceId],
                    "updatedAt": 1,
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: context.storeURL)

        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/available-team", isDirectory: true)
        let taskDirectory = tasksRoot.appendingPathComponent(teamName, isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: "available-leader",
            agentID: "available-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Current task","status":"pending"}"#,
            to: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: currentWorkspaceId,
            surfaceId: currentSurfaceId,
            missingWorkspaceIDs: [closedWorkspaceId]
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = currentWorkspaceId
        environment["CMUX_SURFACE_ID"] = currentSurfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: "available-session",
            agentID: "available-agent"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let rawReconcileRequests = context.state.snapshot().compactMap { line -> [String: Any]? in
            guard let request = ClaudeHookLiveDeliveryHarness.jsonObject(line),
                  request["method"] as? String == "workspace.todo.reconcile" else {
                return nil
            }
            return request["params"] as? [String: Any]
        }
        #expect(rawReconcileRequests.count == 1)
        let rawReconcileRequest = try #require(rawReconcileRequests.first)
        let rawWorkspaceIDs = try #require(rawReconcileRequest["workspace_ids"] as? [String])
        #expect(Set(rawWorkspaceIDs) == Set([
            closedWorkspaceId,
            currentWorkspaceId,
        ]))
        let destinations = reconcileRequests(in: context).compactMap {
            $0["workspace_id"] as? String
        }
        #expect(Set(destinations) == [closedWorkspaceId, currentWorkspaceId])
        let binding = try #require(
            try teamBindingRecords(in: context.storeURL)[bindingKey]
        )
        #expect(binding["workspaceIDs"] as? [String] == [currentWorkspaceId])
    }

    @Test("A team binding is removed when every destination is closed")
    func removesTeamBindingWithNoLiveDestinations() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-no-live-team-workspace"
        )
        defer { context.cleanup() }
        let workspaceId = "90909090-9090-9090-9090-909090909090"
        let surfaceId = "91909090-9090-9090-9090-909090909090"
        let teamName = "Unavailable_Team"
        let tasksRoot = context.root.appendingPathComponent(
            ".claude/tasks",
            isDirectory: true
        )
        let taskStoreIdentity = ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
        let bindingKey = "\(taskStoreIdentity.rawValue):\(teamName)"
        let state: [String: Any] = [
            "version": 1,
            "sessions": [:],
            "claudeTeamTaskBindings": [
                bindingKey: [
                    "binding": [
                        "taskStoreIdentity": ["rawValue": taskStoreIdentity.rawValue],
                        "taskListID": teamName,
                        "leaderSessionID": "unavailable-leader",
                        "agentIDs": ["unavailable-agent"],
                    ],
                    "workspaceIDs": [workspaceId],
                    "updatedAt": 1,
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: context.storeURL)

        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/unavailable-team", isDirectory: true)
        let taskDirectory = tasksRoot.appendingPathComponent(teamName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: teamDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: "unavailable-leader",
            agentID: "unavailable-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Unavailable task","status":"pending"}"#,
            to: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            missingWorkspaceIDs: [workspaceId]
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let result = runHook(
            context: context,
            environment: environment,
            sessionId: "unavailable-session",
            agentID: "unavailable-agent"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(try teamBindingRecords(in: context.storeURL).isEmpty)
    }

    @Test("The binding cap clears and replaces the oldest exact owner")
    func retiresOldestBindingAtCapacity() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "task-sync-binding-cap")
        defer { context.cleanup() }
        let workspaceId = "91919191-9191-9191-9191-919191919191"
        let surfaceId = "92929292-9292-9292-9292-929292929292"
        let tasksRoot = context.root.appendingPathComponent(
            ".claude/tasks",
            isDirectory: true
        )
        let taskStoreIdentity = ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
        let oldestTaskListID = "ArchivedTeam0"
        var bindings: [String: Any] = [:]
        for index in 0..<128 {
            let taskListID = "ArchivedTeam\(index)"
            bindings["\(taskStoreIdentity.rawValue):\(taskListID)"] = [
                "binding": [
                    "taskStoreIdentity": ["rawValue": taskStoreIdentity.rawValue],
                    "taskListID": taskListID,
                    "leaderSessionID": "archived-leader-\(index)",
                    "agentIDs": ["archived-agent-\(index)"],
                ],
                "workspaceIDs": [workspaceId],
                "updatedAt": index,
            ]
        }
        let state: [String: Any] = [
            "version": 1,
            "sessions": [:],
            "claudeTeamTaskBindings": bindings,
        ]
        try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: context.storeURL)

        let teamName = "Current_Team"
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/current-team", isDirectory: true)
        let taskDirectory = tasksRoot.appendingPathComponent(teamName, isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: "current-leader",
            agentID: "current-agent",
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Current task","status":"pending"}"#,
            to: taskDirectory
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
            sessionId: "current-session",
            agentID: "current-agent"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let reconciliations = reconcileRequests(in: context)
        #expect(reconciliations.count == 2)
        #expect(reconciliations[0]["owner_id"] as? String == taskOwnerID(
            directoryName: oldestTaskListID,
            tasksRootURL: tasksRoot
        ))
        #expect((reconciliations[0]["items"] as? [[String: Any]])?.isEmpty == true)
        #expect(reconciliations[1]["owner_id"] as? String == taskOwnerID(
            directoryName: teamName,
            tasksRootURL: tasksRoot
        ))

        let persistedBindings = try teamBindingRecords(in: context.storeURL)
        #expect(persistedBindings.count == 128)
        #expect(!persistedBindings.values.contains { record in
            let binding = record["binding"] as? [String: Any]
            return binding?["taskListID"] as? String == oldestTaskListID
        })
        #expect(persistedBindings.values.contains { record in
            let binding = record["binding"] as? [String: Any]
            return binding?["taskListID"] as? String == teamName
        })
    }

    @Test("A delayed TeamDelete cannot clear a reused team task list")
    func preservesReusedTeamAfterDelayedDelete() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(
            name: "task-sync-reused-team-delete"
        )
        defer { context.cleanup() }
        let workspaceId = "97979797-9797-9797-9797-979797979797"
        let surfaceId = "98989898-9898-9898-9898-989898989898"
        let teamName = "Reused-Team"
        let oldLeaderSessionID = "reused-old-leader"
        let oldAgentID = "reused-old-agent"
        let newLeaderSessionID = "reused-new-leader"
        let newAgentID = "reused-new-agent"
        let teamDirectory = context.root
            .appendingPathComponent(".claude/teams/reused-team", isDirectory: true)
        let taskDirectory = context.root
            .appendingPathComponent(".claude/tasks/\(teamName)", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: oldLeaderSessionID,
            agentID: oldAgentID,
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Old team task","status":"pending"}"#,
            to: taskDirectory
        )
        let deliveries = ClaudeHookLiveDeliveryHarness.startTaskSyncServer(
            context: context,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        var environment = ClaudeHookLiveDeliveryHarness.hookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId

        let oldResult = runHook(
            context: context,
            environment: environment,
            sessionId: oldLeaderSessionID,
            agentID: oldAgentID
        )
        #expect(!oldResult.timedOut, Comment(rawValue: oldResult.stderr))
        #expect(oldResult.status == 0, Comment(rawValue: oldResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)

        // The task-list directory is reused by a new team before an old
        // TeamDelete hook arrives.
        try writeTeamConfig(
            name: teamName,
            leaderSessionID: newLeaderSessionID,
            agentID: newAgentID,
            to: teamDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"New team task","status":"in_progress"}"#,
            to: taskDirectory
        )
        let newResult = runHook(
            context: context,
            environment: environment,
            sessionId: newLeaderSessionID,
            agentID: newAgentID
        )
        #expect(!newResult.timedOut, Comment(rawValue: newResult.stderr))
        #expect(newResult.status == 0, Comment(rawValue: newResult.stderr))
        #expect(deliveries.feed.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.reconciliation.wait(timeout: .now() + 5) == .success)
        let reconciliationCountBeforeDelete = reconcileRequests(in: context).count

        // A failed transition can leave only the destination proof. TeamDelete
        // must still inspect the live config before clearing that owner.
        try removeTeamBindingRecords(storeURL: context.storeURL)

        let deleteResult = runHook(
            context: context,
            environment: environment,
            sessionId: oldLeaderSessionID,
            agentID: oldAgentID,
            toolName: "TeamDelete",
            standardInput: #"{"session_id":"reused-old-leader","agent_id":"reused-old-agent","hook_event_name":"PostToolUse","tool_name":"TeamDelete","tool_input":{"team_name":"Reused-Team"},"tool_response":{"success":true}}"#
        )
        #expect(!deleteResult.timedOut, Comment(rawValue: deleteResult.stderr))
        #expect(deleteResult.status == 0, Comment(rawValue: deleteResult.stderr))
        #expect(reconcileRequests(in: context).count == reconciliationCountBeforeDelete)

        let persistedBinding = try #require(
            try teamBindingRecords(in: context.storeURL).values.first
        )
        let binding = try #require(persistedBinding["binding"] as? [String: Any])
        #expect(binding["leaderSessionID"] as? String == newLeaderSessionID)
        #expect(binding["agentIDs"] as? [String] == [newAgentID])
    }

    private func runHook(
        context: ClaudeHookLiveDeliveryHarness.Context,
        environment: [String: String],
        sessionId: String,
        agentID: String? = nil,
        toolName: String = "TaskUpdate",
        standardInput: String? = nil
    ) -> ClaudeHookLiveDeliveryHarness.ProcessRunResult {
        let defaultInput: String
        if let agentID {
            defaultInput = #"{"session_id":"\#(sessionId)","hook_event_name":"PostToolUse","agent_id":"\#(agentID)","tool_name":"\#(toolName)","tool_input":{"taskId":"1","status":"in_progress"}}"#
        } else {
            defaultInput = #"{"session_id":"\#(sessionId)","hook_event_name":"PostToolUse","tool_name":"\#(toolName)","tool_input":{"taskId":"1","status":"in_progress"}}"#
        }
        return ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "task-sync"],
            environment: environment,
            standardInput: standardInput ?? defaultInput
        )
    }

    private func writeTeamConfig(
        name: String,
        leaderSessionID: String?,
        agentID: String,
        additionalAgentIDs: [String] = [],
        to directory: URL
    ) throws {
        var value: [String: Any] = [
            "name": name,
            "members": ([agentID] + additionalAgentIDs).map { ["agentId": $0] },
        ]
        if let leaderSessionID {
            value["leadAgentId"] = agentID
            value["leadSessionId"] = leaderSessionID
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("config.json"))
    }

    private func writeTask(_ json: String, to directory: URL) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent("1.json"))
    }

    private func reconcileRequests(
        in context: ClaudeHookLiveDeliveryHarness.Context
    ) -> [[String: Any]] {
        ClaudeHookLiveDeliveryHarness.taskSyncReconcileRequests(in: context)
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

    private func teamBindingRecords(
        in storeURL: URL
    ) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: storeURL)
        let state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return state["claudeTeamTaskBindings"] as? [String: [String: Any]] ?? [:]
    }

    private func rewriteTeamBindingAsLegacy(
        taskListID: String,
        storeURL: URL
    ) throws {
        let data = try Data(contentsOf: storeURL)
        var state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let bindings = try #require(
            state["claudeTeamTaskBindings"] as? [String: [String: Any]]
        )
        var record = try #require(bindings.values.first)
        var binding = try #require(record["binding"] as? [String: Any])
        binding.removeValue(forKey: "taskStoreIdentity")
        record["binding"] = binding
        state["claudeTeamTaskBindings"] = [taskListID: record]
        let legacyData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try legacyData.write(to: storeURL)
    }

    private func removeTeamBindingRecords(storeURL: URL) throws {
        let data = try Data(contentsOf: storeURL)
        var state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        state["claudeTeamTaskBindings"] = [String: [String: Any]]()
        let updatedData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: storeURL)
    }
}
