import Foundation
import Testing
import CMUXAgentLaunch

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Feed coordinator", .serialized)
struct FeedCoordinatorTests {
    @Test func codexTeamsResolvesExplicitWorkingDirectoryFlags() {
        let base = "/tmp/cmux-base"

        #expect(
            CodexTeamsApprovalBridge.resolvedWorkingDirectory(
                commandArgs: ["-C", "child", "prompt"],
                baseDirectory: base
            ) == "/tmp/cmux-base/child"
        )
        #expect(
            CodexTeamsApprovalBridge.resolvedWorkingDirectory(
                commandArgs: ["--cwd=/tmp/cmux-review", "--cd", "/tmp/cmux-final"],
                baseDirectory: base
            ) == "/tmp/cmux-final"
        )
        #expect(
            CodexTeamsApprovalBridge.resolvedWorkingDirectory(
                commandArgs: ["--", "-C", "/tmp/inside-prompt"],
                baseDirectory: base
            ) == nil
        )
    }

    @Test func codexTeamsValidatesExplicitWorkingDirectoryExists() throws {
        let existing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-teams-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existing) }

        do {
            try CodexTeamsApprovalBridge.validateWorkingDirectory(
                commandArgs: ["-C", existing.path],
                baseDirectory: "/tmp"
            )
        } catch {
            Issue.record("existing Codex Teams cwd should validate: \(error)")
        }

        do {
            try CodexTeamsApprovalBridge.validateWorkingDirectory(
                commandArgs: ["-C", existing.appendingPathComponent("missing").path],
                baseDirectory: "/tmp"
            )
            Issue.record("missing Codex Teams cwd should throw")
        } catch {
            // expected
        }
    }

    @Test func claudePermissionActionPolicyKeepsBypassUserOwned() {
        #expect(FeedPermissionActionPolicy.supportsPersistentPermissionModes(source: .claude))
        #expect(!FeedPermissionActionPolicy.supportsBypassPermissions(source: .claude))
        #expect(CodexTeamsApprovalBridge.feedSourceSupportsPersistentPermissionModes("claude"))
        #expect(!CodexTeamsApprovalBridge.feedSourceSupportsBypassPermissions("claude"))

        #expect(FeedPermissionActionPolicy.supportsPersistentPermissionModes(source: .codex))
        #expect(!FeedPermissionActionPolicy.supportsBypassPermissions(source: .codex))
        #expect(CodexTeamsApprovalBridge.feedSourceSupportsPersistentPermissionModes("codex"))
        #expect(!CodexTeamsApprovalBridge.feedSourceSupportsBypassPermissions("codex"))

        let codexOneShotOnly = #"""
        {"app_server_method":"item/commandExecution/requestApproval","available_decisions":["accept","decline"]}
        """#
        #expect(FeedPermissionActionPolicy.supportsOncePermissionMode(source: .codex, toolInputJSON: codexOneShotOnly))
        #expect(!FeedPermissionActionPolicy.supportsAlwaysPermissionMode(source: .codex, toolInputJSON: codexOneShotOnly))
        #expect(!FeedPermissionActionPolicy.supportsAllPermissionMode(source: .codex, toolInputJSON: codexOneShotOnly))
        #expect(CodexTeamsApprovalBridge.feedSourceSupportsOncePermissionMode("codex", toolInputJSON: codexOneShotOnly))
        #expect(!CodexTeamsApprovalBridge.feedSourceSupportsAlwaysPermissionMode("codex", toolInputJSON: codexOneShotOnly))
        #expect(!CodexTeamsApprovalBridge.feedSourceSupportsAllPermissionMode("codex", toolInputJSON: codexOneShotOnly))

        let codexSession = #"""
        {"app_server_method":"item/commandExecution/requestApproval","available_decisions":["accept","acceptForSession","decline"]}
        """#
        #expect(FeedPermissionActionPolicy.supportsAlwaysPermissionMode(source: .codex, toolInputJSON: codexSession))
        #expect(CodexTeamsApprovalBridge.feedSourceSupportsAlwaysPermissionMode("codex", toolInputJSON: codexSession))

        let truncatedCodexToolInput = #"{"app_server_method":"item/commandExecution/requestApproval","available_decisions":["accept"]"#
        #expect(!FeedPermissionActionPolicy.supportsOncePermissionMode(source: .codex, toolInputJSON: truncatedCodexToolInput))
        #expect(!FeedPermissionActionPolicy.supportsAlwaysPermissionMode(source: .codex, toolInputJSON: truncatedCodexToolInput))
        #expect(!FeedPermissionActionPolicy.supportsAllPermissionMode(source: .codex, toolInputJSON: truncatedCodexToolInput))
        #expect(!CodexTeamsApprovalBridge.feedSourceSupportsOncePermissionMode("codex", toolInputJSON: truncatedCodexToolInput))
        #expect(!CodexTeamsApprovalBridge.feedSourceSupportsAlwaysPermissionMode("codex", toolInputJSON: truncatedCodexToolInput))
        #expect(!CodexTeamsApprovalBridge.feedSourceSupportsAllPermissionMode("codex", toolInputJSON: truncatedCodexToolInput))

        let codexFileChangeFallback = #"""
        {"app_server_method":"item/fileChange/requestApproval"}
        """#
        #expect(FeedPermissionActionPolicy.supportsAlwaysPermissionMode(source: .codex, toolInputJSON: codexFileChangeFallback))
        #expect(CodexTeamsApprovalBridge.feedSourceSupportsAlwaysPermissionMode("codex", toolInputJSON: codexFileChangeFallback))

        let codexAmendment = #"""
        {"app_server_method":"item/commandExecution/requestApproval","available_decisions":[{"acceptWithExecpolicyAmendment":{}}],"proposed_execpolicy_amendment":[{"kind":"prefix","value":"npm test"}]}
        """#
        #expect(!FeedPermissionActionPolicy.supportsOncePermissionMode(source: .codex, toolInputJSON: codexAmendment))
        #expect(!FeedPermissionActionPolicy.supportsAlwaysPermissionMode(source: .codex, toolInputJSON: codexAmendment))
        #expect(FeedPermissionActionPolicy.supportsAllPermissionMode(source: .codex, toolInputJSON: codexAmendment))
        #expect(!CodexTeamsApprovalBridge.feedSourceSupportsOncePermissionMode("codex", toolInputJSON: codexAmendment))
        #expect(!CodexTeamsApprovalBridge.feedSourceSupportsAlwaysPermissionMode("codex", toolInputJSON: codexAmendment))
        #expect(CodexTeamsApprovalBridge.feedSourceSupportsAllPermissionMode("codex", toolInputJSON: codexAmendment))

        #expect(FeedPermissionActionPolicy.supportsPersistentPermissionModes(source: .opencode))
        #expect(FeedPermissionActionPolicy.supportsBypassPermissions(source: .opencode))
        #expect(CodexTeamsApprovalBridge.feedSourceSupportsPersistentPermissionModes("opencode"))
        #expect(CodexTeamsApprovalBridge.feedSourceSupportsBypassPermissions("opencode"))

        #expect(!FeedPermissionActionPolicy.supportsPersistentPermissionModes(source: .hermesAgent))
        #expect(!FeedPermissionActionPolicy.supportsBypassPermissions(source: .hermesAgent))
        #expect(!CodexTeamsApprovalBridge.feedSourceSupportsPersistentPermissionModes("hermes-agent"))
        #expect(!CodexTeamsApprovalBridge.feedSourceSupportsBypassPermissions("hermes-agent"))
    }

    @Test func codexPermissionListKeepsCapabilitiesWhenToolInputIsTruncated() throws {
        let toolInput: [String: Any] = [
            "app_server_method": "item/commandExecution/requestApproval",
            "available_decisions": ["accept", "acceptForSession", "decline"],
            "related_item": [
                "diff": String(repeating: "x", count: 12_000)
            ]
        ]
        let toolInputData = try JSONSerialization.data(withJSONObject: toolInput, options: [.sortedKeys])
        let toolInputJSON = try #require(String(data: toolInputData, encoding: .utf8))
        let item = WorkstreamItem(
            workstreamId: "codex-thread-1",
            source: .codex,
            kind: .permissionRequest,
            payload: .permissionRequest(
                requestId: "request-1",
                toolName: "Bash",
                toolInputJSON: toolInputJSON,
                pattern: nil
            )
        )

        let dict = FeedSocketEncoding.itemDict(item)
        let displayToolInput = try #require(dict["tool_input"] as? String)
        let capabilityToolInput = try #require(dict["tool_input_capabilities"] as? String)

        #expect(displayToolInput.count == 8_000)
        #expect(dict["tool_input_truncated"] as? Bool == true)
        #expect(capabilityToolInput.count < displayToolInput.count)
        #expect(FeedPermissionActionPolicy.supportsOncePermissionMode(source: .codex, toolInputJSON: capabilityToolInput))
        #expect(FeedPermissionActionPolicy.supportsAlwaysPermissionMode(source: .codex, toolInputJSON: capabilityToolInput))
        #expect(!FeedPermissionActionPolicy.supportsAllPermissionMode(source: .codex, toolInputJSON: capabilityToolInput))
    }

    @Test func codexAppServerApprovalBuildsActionableFeedEvent() throws {
        let event = CodexTeamsApprovalBridge.feedEvent(
            method: "item/commandExecution/requestApproval",
            requestId: 41,
            params: [
                "threadId": "thread-1",
                "turnId": "turn-1",
                "itemId": "call-1",
                "approvalId": "approval-1",
                "command": "touch /tmp/cmux-security-review",
                "cwd": "/tmp/project",
                "reason": "requires approval",
                "unboundedRawPatch": String(repeating: "x", count: 8_000),
                "additionalPermissions": [
                    "fileSystem": ["write": ["/tmp/project"]]
                ],
                "networkApprovalContext": ["host": "example.com"],
                "commandActions": [[
                    "type": "write",
                    "path": "/tmp/cmux-security-review",
                    "diff": String(repeating: "d", count: 8_000)
                ]],
                "proposedExecpolicyAmendment": [["kind": "prefix", "value": "touch"]],
                "availableDecisions": ["accept", "acceptForSession", "decline"]
            ],
            workspaceId: "workspace-1",
            relatedItem: [
                "type": "commandExecution",
                "id": "call-1",
                "command": "touch /tmp/cmux-security-review",
                "cwd": "/tmp/project"
            ]
        )

        #expect(event["session_id"] as? String == "codex-thread-1")
        #expect(event["hook_event_name"] as? String == "PermissionRequest")
        #expect(event["_source"] as? String == "codex")
        #expect(event["workspace_id"] as? String == "workspace-1")
        #expect(event["_opencode_request_id"] as? String == "codex-app-server-approval-1")
        #expect(event["tool_name"] as? String == "Bash")
        #expect(event["cwd"] as? String == "/tmp/project")

        let toolInput = try #require(event["tool_input"] as? [String: Any])
        #expect(toolInput["app_server_method"] as? String == "item/commandExecution/requestApproval")
        #expect(toolInput["request_id"] as? String == "41")
        #expect(toolInput["item_id"] as? String == "approval-1")
        #expect(toolInput["turn_id"] as? String == "turn-1")
        #expect(toolInput["command"] as? String == "touch /tmp/cmux-security-review")
        let approvalParams = try #require(toolInput["approval_params"] as? [String: Any])
        #expect(approvalParams["unboundedRawPatch"] == nil)
        #expect(toolInput["additional_permissions"] != nil)
        #expect(toolInput["network_approval_context"] != nil)
        let commandActions = try #require(toolInput["command_actions"] as? [[String: Any]])
        #expect((commandActions.first?["diff"] as? String)?.count == 4_096)
        #expect(toolInput["proposed_execpolicy_amendment"] != nil)
        #expect((toolInput["related_item"] as? [String: Any])?["type"] as? String == "commandExecution")

        let context = try #require(event["context"] as? [String: Any])
        #expect(context["permissionMode"] as? String == "codex app-server")
        #expect(context["assistantPreamble"] as? String == "requires approval")
    }

    @Test func codexAppServerPermissionsApprovalBuildsFeedEventAndResponse() throws {
        let permissions: [String: Any] = [
            "network": ["enabled": true],
            "fileSystem": [
                "read": ["/tmp/read"],
                "write": ["/tmp/write"]
            ]
        ]
        let event = CodexTeamsApprovalBridge.feedEvent(
            method: "item/permissions/requestApproval",
            requestId: "permissions-request",
            params: [
                "threadId": "thread-1",
                "turnId": "turn-1",
                "itemId": "permissions-call",
                "environmentId": "local",
                "cwd": "/tmp/project",
                "reason": "Need broader access",
                "permissions": permissions
            ],
            workspaceId: "workspace-1"
        )

        #expect(event["tool_name"] as? String == "request_permissions")
        #expect(event["_opencode_request_id"] as? String == "codex-app-server-permissions-call")
        let toolInput = try #require(event["tool_input"] as? [String: Any])
        #expect(toolInput["app_server_method"] as? String == "item/permissions/requestApproval")
        #expect(toolInput["approval_params"] != nil)
        #expect(toolInput["permissions"] != nil)

        let once = try #require(
            CodexTeamsApprovalBridge.appServerApprovalResponse(
                method: "item/permissions/requestApproval",
                params: ["permissions": permissions],
                mode: "once"
            )
        )
        #expect(once["scope"] as? String == "turn")
        #expect(once["permissions"] != nil)

        let always = try #require(
            CodexTeamsApprovalBridge.appServerApprovalResponse(
                method: "item/permissions/requestApproval",
                params: ["permissions": permissions],
                mode: "always"
            )
        )
        #expect(always["scope"] as? String == "session")

        let deny = try #require(
            CodexTeamsApprovalBridge.appServerApprovalResponse(
                method: "item/permissions/requestApproval",
                params: ["permissions": permissions],
                mode: "deny"
            )
        )
        #expect(deny["scope"] as? String == "turn")
        #expect((deny["permissions"] as? [String: Any])?.isEmpty == true)
    }

    @Test func codexAppServerApprovalResponseFollowsFeedDecision() {
        let params: [String: Any] = [
            "availableDecisions": ["accept", "acceptForSession", "decline"]
        ]

        #expect(
            CodexTeamsApprovalBridge.permissionMode(fromFeedPushResponse: [
                "status": "resolved",
                "decision": ["kind": "permission", "mode": "always"]
            ]) == "always"
        )
        #expect(
            CodexTeamsApprovalBridge.appServerApprovalResponse(
                method: "item/commandExecution/requestApproval",
                params: params,
                mode: "always"
            )?["decision"] as? String == "acceptForSession"
        )
        #expect(
            CodexTeamsApprovalBridge.appServerApprovalResponse(
                method: "item/commandExecution/requestApproval",
                params: [:],
                mode: "always"
            )?["decision"] as? String == "acceptForSession"
        )
        let amendmentDecision = CodexTeamsApprovalBridge.appServerApprovalResponse(
            method: "item/commandExecution/requestApproval",
            params: [
                "availableDecisions": [["acceptWithExecpolicyAmendment": [:]]],
                "proposedExecpolicyAmendment": [["kind": "prefix", "value": "npm test"]]
            ],
            mode: "always"
        )?["decision"] as? [String: Any]
        #expect(amendmentDecision?["acceptWithExecpolicyAmendment"] != nil)
        let onceAmendmentDecision = CodexTeamsApprovalBridge.appServerApprovalResponse(
            method: "item/commandExecution/requestApproval",
            params: [
                "availableDecisions": [["applyNetworkPolicyAmendment": [:]]],
                "proposedNetworkPolicyAmendments": [["host": "example.com"]]
            ],
            mode: "once"
        )?["decision"] as? String
        #expect(onceAmendmentDecision == "decline")
        let unspecifiedAmendmentDecision = CodexTeamsApprovalBridge.appServerApprovalResponse(
            method: "item/commandExecution/requestApproval",
            params: [
                "proposedExecpolicyAmendment": [["kind": "prefix", "value": "npm test"]]
            ],
            mode: "all"
        )?["decision"] as? [String: Any]
        #expect(unspecifiedAmendmentDecision?["acceptWithExecpolicyAmendment"] != nil)
        let mixedParams: [String: Any] = [
            "availableDecisions": [
                "acceptForSession",
                ["acceptWithExecpolicyAmendment": [:]]
            ],
            "proposedExecpolicyAmendment": [["kind": "prefix", "value": "npm test"]]
        ]
        #expect(
            CodexTeamsApprovalBridge.appServerApprovalResponse(
                method: "item/commandExecution/requestApproval",
                params: mixedParams,
                mode: "always"
            )?["decision"] as? String == "acceptForSession"
        )
        let allToolsDecision = CodexTeamsApprovalBridge.appServerApprovalResponse(
            method: "item/commandExecution/requestApproval",
            params: mixedParams,
            mode: "all"
        )?["decision"] as? [String: Any]
        #expect(allToolsDecision?["acceptWithExecpolicyAmendment"] != nil)
        #expect(
            CodexTeamsApprovalBridge.appServerApprovalResponse(
                method: "item/commandExecution/requestApproval",
                params: ["availableDecisions": ["decline"]],
                mode: "once"
            )?["decision"] as? String == "decline"
        )
        #expect(
            CodexTeamsApprovalBridge.appServerApprovalResponse(
                method: "item/commandExecution/requestApproval",
                params: ["availableDecisions": ["accept", "decline"]],
                mode: "always"
            )?["decision"] as? String == "accept"
        )
        #expect(
            CodexTeamsApprovalBridge.appServerApprovalResponse(
                method: "item/fileChange/requestApproval",
                params: [:],
                mode: "once"
            )?["decision"] as? String == "accept"
        )
        #expect(
            CodexTeamsApprovalBridge.appServerApprovalResponse(
                method: "item/fileChange/requestApproval",
                params: [:],
                mode: "always"
            )?["decision"] as? String == "acceptForSession"
        )
        #expect(
            CodexTeamsApprovalBridge.appServerApprovalResponse(
                method: "item/fileChange/requestApproval",
                params: ["availableDecisions": ["acceptForSession", "decline"]],
                mode: "always"
            )?["decision"] as? String == "acceptForSession"
        )
        #expect(
            CodexTeamsApprovalBridge.appServerApprovalResponse(
                method: "item/fileChange/requestApproval",
                params: ["availableDecisions": ["accept", "decline"]],
                mode: "always"
            )?["decision"] as? String == "accept"
        )
        #expect(
            CodexTeamsApprovalBridge.appServerApprovalResponse(
                method: "item/commandExecution/requestApproval",
                params: params,
                mode: "deny"
            )?["decision"] as? String == "decline"
        )
        #expect(CodexTeamsApprovalBridge.permissionMode(fromFeedPushResponse: ["status": "timed_out"]) == nil)
    }

    @Test func codexApprovalItemSnapshotStripsLargePayloads() throws {
        let snapshot = CodexTeamsApprovalBridge.approvalItemSnapshot([
            "id": "call-1",
            "type": "commandExecution",
            "command": String(repeating: "x", count: 5_000),
            "cwd": "/tmp/project",
            "output": String(repeating: "y", count: 100_000),
            "changes": [
                [
                    "path": "/tmp/file.txt",
                    "diff": String(repeating: "z", count: 100_000),
                    "summary": "file summary"
                ]
            ]
        ])

        #expect(snapshot["id"] as? String == "call-1")
        #expect(snapshot["cwd"] as? String == "/tmp/project")
        #expect((snapshot["command"] as? String)?.count == 4_096)
        #expect(snapshot["output"] == nil)
        let changes = try #require(snapshot["changes"] as? [[String: Any]])
        #expect(changes.first?["path"] as? String == "/tmp/file.txt")
        #expect((changes.first?["diff"] as? String)?.count == 4_096)
        #expect(changes.first?["summary"] as? String == "file summary")
    }

    @Test func blockingIngestExpiresItemWhenHookTimesOut() async {
        await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
        }

        let event = WorkstreamEvent(
            sessionId: "claude-timeout-test",
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: "Bash",
            toolInputJSON: #"{"command":"true"}"#,
            requestId: "timeout-request"
        )

        let done = DispatchSemaphore(value: 0)
        let resultBox = IngestResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            resultBox.value = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 0.05
            )
            done.signal()
        }

        #expect(done.wait(timeout: .now() + 2) == .success)

        guard case .timedOut = resultBox.value else {
            Issue.record("expected feed.push to time out")
            return
        }

        let status = await MainActor.run {
            FeedCoordinator.shared.store.items.first?.status
        }
        guard case .expired = status else {
            Issue.record("timed-out hook item should be expired")
            return
        }
    }

    @Test func blockingIngestSkipsNotificationWhenPermissionResolvesBeforeDisplay() async {
        let requestId = "auto-allow-request"
        let notifications = NotificationRequestRecorder()

        defer {
            Self.resetFeedCoordinatorTestHooks()
        }

        await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
            FeedCoordinatorTestHooks.afterBlockingEventIngested = { _, ingestedRequestId in
                guard ingestedRequestId == requestId else { return }
                FeedCoordinator.shared.deliverReply(
                    requestId: ingestedRequestId,
                    decision: .permission(.once)
                )
            }
            FeedCoordinatorTestHooks.isAppActiveOverride = { false }
            FeedCoordinatorTestHooks.notificationPostObserver = { _, postedRequestId in
                notifications.record(postedRequestId)
            }
        }

        let event = WorkstreamEvent(
            sessionId: "claude-auto-allow-test",
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: "Bash",
            toolInputJSON: #"{"command":"true"}"#,
            requestId: requestId
        )

        let done = DispatchSemaphore(value: 0)
        let resultBox = IngestResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            resultBox.value = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 1
            )
            done.signal()
        }

        #expect(done.wait(timeout: .now() + 2) == .success)

        await MainActor.run {}

        guard case .resolved(_, .permission(.once)) = resultBox.value else {
            Issue.record("expected auto-allowed permission request to resolve")
            return
        }

        let status = await MainActor.run {
            FeedCoordinator.shared.store.items.first?.status
        }
        guard case .resolved(.permission(.once), _) = status else {
            Issue.record("auto-allowed hook item should be resolved")
            return
        }

        #expect(
            notifications.requestIds.isEmpty,
            "auto-allowed permission requests should not post native notifications"
        )
    }

    @Test func blockingIngestSurfacesNeedsInputAttentionForPermissionRequest() async {
        defer {
            Self.resetFeedCoordinatorTestHooks()
        }

        let attention = AttentionSurfaceRecorder()
        let requestId = "needs-input-attention-request"

        await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
            FeedCoordinatorTestHooks.attentionSurfaceObserver = { event in
                attention.record(event)
            }
            // Resolve the blocking wait as soon as the item is ingested so
            // the worker thread does not park for the full timeout.
            FeedCoordinatorTestHooks.afterBlockingEventIngested = { _, ingestedRequestId in
                guard ingestedRequestId == requestId else { return }
                FeedCoordinator.shared.deliverReply(
                    requestId: ingestedRequestId,
                    decision: .permission(.once)
                )
            }
        }

        let event = WorkstreamEvent(
            sessionId: "claude-needs-input-test",
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: "Bash",
            toolInputJSON: #"{"command":"true"}"#,
            requestId: requestId
        )

        let done = DispatchSemaphore(value: 0)
        let resultBox = IngestResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            resultBox.value = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 1
            )
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 2) == .success)
        await MainActor.run {}

        #expect(
            attention.events.count == 1,
            "a blocking PermissionRequest must request in-app needs-input attention surfacing"
        )
        #expect(attention.events.first?.hookEventName == .permissionRequest)
    }

    @Test func blockingDecisionEventPredicateCoversEveryDecisionKind() {
        // The three blocking-decision kinds must all surface attention…
        #expect(FeedCoordinator.isBlockingDecisionEvent(.permissionRequest))
        #expect(FeedCoordinator.isBlockingDecisionEvent(.exitPlanMode))
        #expect(FeedCoordinator.isBlockingDecisionEvent(.askUserQuestion))
        // …and pure telemetry must not.
        #expect(!FeedCoordinator.isBlockingDecisionEvent(.preToolUse))
        #expect(!FeedCoordinator.isBlockingDecisionEvent(.stop))
        #expect(!FeedCoordinator.isBlockingDecisionEvent(.notification))
        #expect(!FeedCoordinator.isBlockingDecisionEvent(.userPromptSubmit))
    }

    @Test func lifecycleStatusKeyMatchesAgentReportedKey() {
        // Claude reports its lifecycle under `claude_code`; reusing that key is
        // what lets Claude's own resume hooks clear the needs-input badge.
        #expect(FeedCoordinator.lifecycleStatusKey(forSource: "claude") == "claude_code")
        // Every other agent keys its status by its own source name.
        #expect(FeedCoordinator.lifecycleStatusKey(forSource: "codex") == "codex")
        #expect(FeedCoordinator.lifecycleStatusKey(forSource: "opencode") == "opencode")
    }

    private static func resetFeedCoordinatorTestHooks() {
        let reset: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                FeedCoordinatorTestHooks.afterBlockingEventIngested = nil
                FeedCoordinatorTestHooks.isAppActiveOverride = nil
                FeedCoordinatorTestHooks.notificationPostObserver = nil
                FeedCoordinatorTestHooks.attentionSurfaceObserver = nil
            }
        }
        if Thread.isMainThread {
            reset()
        } else {
            DispatchQueue.main.sync(execute: reset)
        }
    }

    // Regression coverage for https://github.com/manaflow-ai/cmux/issues/5698:
    // `cmux codex-teams` must learn the spawned subagent's thread id from the
    // Codex app-server `item/completed` notification for a `spawnAgent`
    // collab-agent tool call, otherwise it never opens the subagent split.
    @Test func codexTeamsParsesSpawnedSubagentFromItemCompleted() {
        let message: [String: Any] = [
            "method": "item/completed",
            "params": [
                "threadId": "thread-parent",
                "turnId": "turn-1",
                "item": [
                    "id": "call-1",
                    "type": "collabAgentToolCall",
                    "tool": "spawnAgent",
                    "status": "completed",
                    "senderThreadId": "thread-parent",
                    "receiverThreadIds": ["thread-child"]
                ]
            ]
        ]
        let spawned = CMUXCLI.codexTeamsSpawnedSubagents(fromItemNotification: message)
        #expect(spawned?.parentThreadId == "thread-parent")
        #expect(spawned?.childThreadIds == ["thread-child"])
    }

    @Test func codexTeamsSpawnFallsBackToNotificationThreadIdForParent() {
        // Older/edge payloads may omit `senderThreadId`; the spawning thread is
        // then the notification's own `threadId`.
        let message: [String: Any] = [
            "method": "item/completed",
            "params": [
                "threadId": "thread-parent",
                "item": [
                    "type": "collabAgentToolCall",
                    "tool": "spawnAgent",
                    "receiverThreadIds": ["thread-child-a", "thread-child-b"]
                ]
            ]
        ]
        let spawned = CMUXCLI.codexTeamsSpawnedSubagents(fromItemNotification: message)
        #expect(spawned?.parentThreadId == "thread-parent")
        #expect(spawned?.childThreadIds == ["thread-child-a", "thread-child-b"])
    }

    @Test func codexTeamsSpawnParsesSnakeCasePayload() {
        let message: [String: Any] = [
            "method": "item/completed",
            "params": [
                "thread_id": "thread-parent",
                "item": [
                    "type": "collabAgentToolCall",
                    "tool": "spawnAgent",
                    "sender_thread_id": "thread-parent",
                    "receiver_thread_ids": ["thread-child"]
                ]
            ]
        ]
        let spawned = CMUXCLI.codexTeamsSpawnedSubagents(fromItemNotification: message)
        #expect(spawned?.parentThreadId == "thread-parent")
        #expect(spawned?.childThreadIds == ["thread-child"])
    }

    @Test func codexTeamsSpawnParsesSnakeCaseTypeAndTool() {
        // The discriminator values themselves must match across camelCase and
        // snake_case spellings, not just the key names.
        let message: [String: Any] = [
            "method": "item/completed",
            "params": [
                "threadId": "thread-parent",
                "item": [
                    "type": "collab_agent_tool_call",
                    "tool": "spawn_agent",
                    "senderThreadId": "thread-parent",
                    "receiverThreadIds": ["thread-child"]
                ]
            ]
        ]
        let spawned = CMUXCLI.codexTeamsSpawnedSubagents(fromItemNotification: message)
        #expect(spawned?.parentThreadId == "thread-parent")
        #expect(spawned?.childThreadIds == ["thread-child"])
    }

    @Test func codexTeamsSpawnIgnoresFailedSpawnWithNoReceivers() {
        // A failed spawn carries an empty `receiverThreadIds`; there is no child
        // to open, so the watcher must not treat it as a spawn.
        let message: [String: Any] = [
            "method": "item/completed",
            "params": [
                "threadId": "thread-parent",
                "item": [
                    "type": "collabAgentToolCall",
                    "tool": "spawnAgent",
                    "status": "failed",
                    "senderThreadId": "thread-parent",
                    "receiverThreadIds": [String]()
                ]
            ]
        ]
        #expect(CMUXCLI.codexTeamsSpawnedSubagents(fromItemNotification: message) == nil)
    }

    @Test func codexTeamsSpawnIgnoresNonSpawnCollabTools() {
        let message: [String: Any] = [
            "method": "item/completed",
            "params": [
                "threadId": "thread-parent",
                "item": [
                    "type": "collabAgentToolCall",
                    "tool": "sendInput",
                    "senderThreadId": "thread-parent",
                    "receiverThreadIds": ["thread-child"]
                ]
            ]
        ]
        #expect(CMUXCLI.codexTeamsSpawnedSubagents(fromItemNotification: message) == nil)
    }

    @Test func codexTeamsSpawnIgnoresNonCollabItems() {
        let message: [String: Any] = [
            "method": "item/completed",
            "params": [
                "threadId": "thread-parent",
                "item": [
                    "type": "commandExecution",
                    "receiverThreadIds": ["thread-child"]
                ]
            ]
        ]
        #expect(CMUXCLI.codexTeamsSpawnedSubagents(fromItemNotification: message) == nil)
    }

    @Test func codexTeamsSpawnIgnoresNonCompletedNotifications() {
        // Spawn start arrives as `item/started` before the child exists; only
        // the `item/completed` spawn end carries the resolved child thread id.
        let message: [String: Any] = [
            "method": "item/started",
            "params": [
                "threadId": "thread-parent",
                "item": [
                    "type": "collabAgentToolCall",
                    "tool": "spawnAgent",
                    "senderThreadId": "thread-parent",
                    "receiverThreadIds": ["thread-child"]
                ]
            ]
        ]
        #expect(CMUXCLI.codexTeamsSpawnedSubagents(fromItemNotification: message) == nil)
    }
}

private final class IngestResultBox: @unchecked Sendable {
    var value: FeedCoordinator.IngestBlockingResult?
}

private final class AttentionSurfaceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [WorkstreamEvent] = []

    var events: [WorkstreamEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func record(_ event: WorkstreamEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

private final class NotificationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequestIds: [String] = []

    var requestIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequestIds
    }

    func record(_ requestId: String) {
        lock.lock()
        recordedRequestIds.append(requestId)
        lock.unlock()
    }
}
