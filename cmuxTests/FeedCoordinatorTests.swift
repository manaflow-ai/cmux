import XCTest
import CMUXWorkstream

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FeedCoordinatorTests: XCTestCase {
    func testCodexTeamsResolvesExplicitWorkingDirectoryFlags() throws {
        let base = "/tmp/cmux-base"

        XCTAssertEqual(
            CMUXCLI.codexTeamsResolvedWorkingDirectory(
                commandArgs: ["-C", "child", "prompt"],
                baseDirectory: base
            ),
            "/tmp/cmux-base/child"
        )
        XCTAssertEqual(
            CMUXCLI.codexTeamsResolvedWorkingDirectory(
                commandArgs: ["--cwd=/tmp/cmux-review", "--cd", "/tmp/cmux-final"],
                baseDirectory: base
            ),
            "/tmp/cmux-final"
        )
        XCTAssertNil(
            CMUXCLI.codexTeamsResolvedWorkingDirectory(
                commandArgs: ["--", "-C", "/tmp/inside-prompt"],
                baseDirectory: base
            )
        )
    }

    func testCodexTeamsValidatesExplicitWorkingDirectoryExists() throws {
        let existing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-teams-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existing) }

        XCTAssertNoThrow(
            try CMUXCLI.validateCodexTeamsWorkingDirectory(
                commandArgs: ["-C", existing.path],
                baseDirectory: "/tmp"
            )
        )

        XCTAssertThrowsError(
            try CMUXCLI.validateCodexTeamsWorkingDirectory(
                commandArgs: ["-C", existing.appendingPathComponent("missing").path],
                baseDirectory: "/tmp"
            )
        )
    }

    func testClaudePermissionActionPolicyKeepsBypassUserOwned() {
        XCTAssertTrue(FeedPermissionActionPolicy.supportsPersistentPermissionModes(source: .claude))
        XCTAssertFalse(FeedPermissionActionPolicy.supportsBypassPermissions(source: .claude))

        XCTAssertTrue(FeedPermissionActionPolicy.supportsPersistentPermissionModes(source: .codex))
        XCTAssertFalse(FeedPermissionActionPolicy.supportsBypassPermissions(source: .codex))

        XCTAssertTrue(FeedPermissionActionPolicy.supportsPersistentPermissionModes(source: .opencode))
        XCTAssertTrue(FeedPermissionActionPolicy.supportsBypassPermissions(source: .opencode))

        XCTAssertFalse(FeedPermissionActionPolicy.supportsPersistentPermissionModes(source: .hermesAgent))
        XCTAssertFalse(FeedPermissionActionPolicy.supportsBypassPermissions(source: .hermesAgent))
    }

    func testCodexAppServerApprovalBuildsActionableFeedEvent() throws {
        let event = CMUXCLI.codexTeamsFeedEvent(
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
                "availableDecisions": ["accept", "acceptForSession", "decline"]
            ],
            workspaceId: "workspace-1"
        )

        XCTAssertEqual(event["session_id"] as? String, "codex-thread-1")
        XCTAssertEqual(event["hook_event_name"] as? String, "PermissionRequest")
        XCTAssertEqual(event["_source"] as? String, "codex")
        XCTAssertEqual(event["workspace_id"] as? String, "workspace-1")
        XCTAssertEqual(event["_opencode_request_id"] as? String, "codex-app-server-approval-1")
        XCTAssertEqual(event["tool_name"] as? String, "Bash")
        XCTAssertEqual(event["cwd"] as? String, "/tmp/project")

        let toolInput = try XCTUnwrap(event["tool_input"] as? [String: Any])
        XCTAssertEqual(toolInput["app_server_method"] as? String, "item/commandExecution/requestApproval")
        XCTAssertEqual(toolInput["request_id"] as? String, "41")
        XCTAssertEqual(toolInput["item_id"] as? String, "approval-1")
        XCTAssertEqual(toolInput["turn_id"] as? String, "turn-1")
        XCTAssertEqual(toolInput["command"] as? String, "touch /tmp/cmux-security-review")

        let context = try XCTUnwrap(event["context"] as? [String: Any])
        XCTAssertEqual(context["permissionMode"] as? String, "codex app-server")
        XCTAssertEqual(context["assistantPreamble"] as? String, "requires approval")
    }

    func testCodexAppServerApprovalResponseFollowsFeedDecision() {
        let params: [String: Any] = [
            "availableDecisions": ["accept", "acceptForSession", "decline"]
        ]

        XCTAssertEqual(
            CMUXCLI.codexTeamsPermissionMode(fromFeedPushResponse: [
                "status": "resolved",
                "decision": ["kind": "permission", "mode": "always"]
            ]),
            "always"
        )
        XCTAssertEqual(
            CMUXCLI.codexTeamsAppServerApprovalResponse(
                method: "item/commandExecution/requestApproval",
                params: params,
                mode: "always"
            )?["decision"] as? String,
            "acceptForSession"
        )
        XCTAssertEqual(
            CMUXCLI.codexTeamsAppServerApprovalResponse(
                method: "item/fileChange/requestApproval",
                params: [:],
                mode: "once"
            )?["decision"] as? String,
            "accept"
        )
        XCTAssertEqual(
            CMUXCLI.codexTeamsAppServerApprovalResponse(
                method: "item/commandExecution/requestApproval",
                params: params,
                mode: "deny"
            )?["decision"] as? String,
            "decline"
        )
        XCTAssertNil(CMUXCLI.codexTeamsPermissionMode(fromFeedPushResponse: ["status": "timed_out"]))
    }

    func testBlockingIngestExpiresItemWhenHookTimesOut() async {
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

        let done = expectation(description: "blocking ingest timed out")
        let resultBox = IngestResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            resultBox.value = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 0.05
            )
            done.fulfill()
        }

        await fulfillment(of: [done], timeout: 2)

        guard case .timedOut = resultBox.value else {
            XCTFail("expected feed.push to time out")
            return
        }

        let status = await MainActor.run {
            FeedCoordinator.shared.store.items.first?.status
        }
        guard case .expired = status else {
            XCTFail("timed-out hook item should be expired")
            return
        }
    }

    func testBlockingIngestSkipsNotificationWhenPermissionResolvesBeforeDisplay() async {
        let requestId = "auto-allow-request"
        let notifications = NotificationRequestRecorder()

        addTeardownBlock {
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

        let done = expectation(description: "blocking ingest resolved")
        let resultBox = IngestResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            resultBox.value = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 1
            )
            done.fulfill()
        }

        await fulfillment(of: [done], timeout: 2)

        await MainActor.run {}

        if case .resolved(_, .permission(.once)) = resultBox.value {
            // ok
        } else {
            XCTFail("expected auto-allowed permission request to resolve")
        }

        let status = await MainActor.run {
            FeedCoordinator.shared.store.items.first?.status
        }
        if case .resolved(.permission(.once), _) = status {
            // ok
        } else {
            XCTFail("auto-allowed hook item should be resolved")
        }

        XCTAssertTrue(
            notifications.requestIds.isEmpty,
            "auto-allowed permission requests should not post native notifications"
        )
    }

    private static func resetFeedCoordinatorTestHooks() {
        let reset: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                FeedCoordinatorTestHooks.afterBlockingEventIngested = nil
                FeedCoordinatorTestHooks.isAppActiveOverride = nil
                FeedCoordinatorTestHooks.notificationPostObserver = nil
            }
        }
        if Thread.isMainThread {
            reset()
        } else {
            DispatchQueue.main.sync(execute: reset)
        }
    }
}

private final class IngestResultBox: @unchecked Sendable {
    var value: FeedCoordinator.IngestBlockingResult?
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
