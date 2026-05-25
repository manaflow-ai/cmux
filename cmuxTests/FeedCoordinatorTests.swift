import XCTest
import CMUXWorkstream
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FeedCoordinatorTests: XCTestCase {
    func testFeedReplyRPCRequiresItemID() throws {
        let cases: [(method: String, params: [String: Any])] = [
            ("feed.permission.reply", ["request_id": "req-1", "mode": "once"]),
            ("feed.question.reply", ["request_id": "req-1", "selections": ["yes"]]),
            ("feed.exit_plan.reply", ["request_id": "req-1", "mode": "manual"])
        ]

        for testCase in cases {
            let error = try Self.v2Error(method: testCase.method, params: testCase.params)
            XCTAssertEqual(error["code"] as? String, "invalid_params")
            XCTAssertEqual(error["message"] as? String, "\(testCase.method) requires item_id")
        }
    }

    func testPrivilegedFeedNotificationActionsRequireAuthentication() {
        let privileged = FeedNotificationActionSecurity.privilegedActionIdentifiers
        XCTAssertFalse(privileged.isEmpty)
        for identifier in privileged {
            XCTAssertTrue(
                FeedNotificationActionSecurity.options(for: identifier).contains(.authenticationRequired),
                "\(identifier) should require authentication before resolving an agent decision"
            )
        }

        XCTAssertTrue(
            FeedNotificationActionSecurity.options(
                for: "feed.diff.reject",
                additional: [.destructive]
            ).contains(.authenticationRequired)
        )
    }

    func testClaudePermissionActionPolicyKeepsBypassUserOwned() {
        XCTAssertTrue(FeedPermissionActionPolicy.supportsPersistentPermissionModes(source: .claude))
        XCTAssertFalse(FeedPermissionActionPolicy.supportsBypassPermissions(source: .claude))

        XCTAssertFalse(FeedPermissionActionPolicy.supportsPersistentPermissionModes(source: .codex))
        XCTAssertFalse(FeedPermissionActionPolicy.supportsBypassPermissions(source: .codex))

        XCTAssertTrue(FeedPermissionActionPolicy.supportsPersistentPermissionModes(source: .opencode))
        XCTAssertTrue(FeedPermissionActionPolicy.supportsBypassPermissions(source: .opencode))

        XCTAssertFalse(FeedPermissionActionPolicy.supportsPersistentPermissionModes(source: .hermesAgent))
        XCTAssertFalse(FeedPermissionActionPolicy.supportsBypassPermissions(source: .hermesAgent))
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
            FeedCoordinatorTestHooks.notificationPostObserver = { _, postedRequestId, _ in
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

    func testBlockingDiffApprovalPostsNativeDiffNotificationWhenInactive() async {
        let requestId = "diff-native-notification-request"
        let posted = expectation(description: "diff approval notification posted")
        let categories = NotificationRequestRecorder()

        addTeardownBlock {
            Self.resetFeedCoordinatorTestHooks()
        }

        await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
            FeedCoordinatorTestHooks.isAppActiveOverride = { false }
            FeedCoordinatorTestHooks.notificationPostObserver = { event, postedRequestId, categoryId in
                guard postedRequestId == requestId,
                      event.hookEventName == .diffApprovalRequest
                else { return }
                categories.record(categoryId)
                posted.fulfill()
            }
        }

        let event = WorkstreamEvent(
            sessionId: "codex-diff-native-notification-test",
            hookEventName: .diffApprovalRequest,
            source: "codex",
            cwd: "/tmp",
            toolName: "DiffApprovalRequest",
            toolInputJSON: #"{"patch":"diff --git a/file b/file"}"#,
            requestId: requestId
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

        await fulfillment(of: [posted, done], timeout: 2)

        XCTAssertEqual(categories.requestIds, ["CMUXFeedDiffApproval"])
        guard case .timedOut = resultBox.value else {
            XCTFail("expected unresolved diff approval hook to time out")
            return
        }
    }

    func testDeliverReplyRejectsUnknownRequest() async {
        await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
        }

        let result = FeedCoordinator.shared.deliverReply(
            requestId: "missing-request",
            decision: .permission(.once)
        )

        XCTAssertEqual(result, .notFound)
    }

    func testDeliverReplyResolvesPendingStoreItemWithoutLiveWaiter() async {
        let requestId = "pending-store-request"
        await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
            store.ingest(WorkstreamEvent(
                sessionId: "claude-nonblocking-test",
                hookEventName: .permissionRequest,
                source: "claude",
                cwd: "/tmp",
                toolName: "Bash",
                toolInputJSON: #"{"command":"true"}"#,
                requestId: requestId
            ))
        }

        let result = FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: .permission(.once)
        )

        XCTAssertEqual(result, .delivered(waiterSignaled: false, storeResolved: true))
        let status = await MainActor.run {
            FeedCoordinator.shared.store.items.first?.status
        }
        if case .resolved(.permission(.once), _) = status {
            // ok
        } else {
            XCTFail("pending store item should be resolved")
        }
    }

    func testDeliverReplyRejectsMismatchedItemID() async {
        let requestId = "pending-store-request-with-item"
        let itemId = await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
            store.ingest(WorkstreamEvent(
                sessionId: "claude-item-bound-test",
                hookEventName: .permissionRequest,
                source: "claude",
                cwd: "/tmp",
                toolName: "Bash",
                toolInputJSON: #"{"command":"true"}"#,
                requestId: requestId
            ))
            return store.items[0].id
        }

        let result = FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            itemId: "00000000-0000-0000-0000-000000000000",
            decision: .permission(.once)
        )

        XCTAssertEqual(result, .notFound)
        let status = await MainActor.run {
            FeedCoordinator.shared.store.items.first?.status
        }
        XCTAssertTrue(status?.isPending ?? false)

        let delivered = FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            itemId: itemId.uuidString,
            decision: .permission(.once)
        )
        XCTAssertEqual(delivered, .delivered(waiterSignaled: false, storeResolved: true))
    }

    func testGroupedQuestionSelectionsResolveDuplicateOptionIDsByQuestionID() async {
        let requestId = "multi-question-request"
        let itemId = await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
            store.ingest(WorkstreamEvent(
                sessionId: "claude-question-test",
                hookEventName: .askUserQuestion,
                source: "claude",
                cwd: "/tmp",
                toolName: "AskUserQuestion",
                toolInputJSON: """
                {
                  "questions": [
                    {
                      "id": "target",
                      "question": "Target?",
                      "options": [
                        {"id": "yes", "label": "iOS"},
                        {"id": "no", "label": "macOS"}
                      ]
                    },
                    {
                      "id": "risk",
                      "question": "Risk?",
                      "options": [
                        {"id": "yes", "label": "Low"},
                        {"id": "no", "label": "High"}
                      ]
                    }
                  ]
                }
                """,
                requestId: requestId
            ))
            return store.items[0].id.uuidString
        }

        let labels = FeedCoordinator.shared.questionSelectionLabels(
            requestId: requestId,
            itemId: itemId,
            questionSelections: [
                (questionId: "target", optionIds: ["yes"]),
                (questionId: "risk", optionIds: ["yes"])
            ]
        )

        XCTAssertEqual(labels, ["iOS", "Low"])
    }

    func testGroupedQuestionSelectionsRejectMismatchedItemID() async {
        let requestId = "stale-question-request"
        await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
            store.ingest(WorkstreamEvent(
                sessionId: "claude-question-test",
                hookEventName: .askUserQuestion,
                source: "claude",
                cwd: "/tmp",
                toolName: "AskUserQuestion",
                toolInputJSON: """
                {
                  "questions": [
                    {
                      "id": "target",
                      "question": "Target?",
                      "options": [
                        {"id": "yes", "label": "iOS"}
                      ]
                    }
                  ]
                }
                """,
                requestId: requestId
            ))
        }

        let labels = FeedCoordinator.shared.questionSelectionLabels(
            requestId: requestId,
            itemId: UUID().uuidString,
            questionSelections: [
                (questionId: "target", optionIds: ["yes"])
            ]
        )

        XCTAssertNil(labels)
    }

    func testDiffApprovalRequestSurfacesAsDiffDecisionAndResolves() async {
        let requestId = "diff-approval-request"
        await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
            store.ingest(WorkstreamEvent(
                sessionId: "codex-diff-test",
                hookEventName: .diffApprovalRequest,
                source: "codex",
                cwd: "/tmp",
                toolName: "DiffApprovalRequest",
                toolInputJSON: #"{"patch":"diff --git a/file b/file"}"#,
                requestId: requestId
            ))
        }

        let pendingDict = await MainActor.run {
            FeedSocketEncoding.itemDict(FeedCoordinator.shared.store.items[0])
        }
        XCTAssertEqual(pendingDict["kind"] as? String, "permissionRequest")
        XCTAssertEqual(pendingDict["request_id"] as? String, requestId)
        XCTAssertEqual(pendingDict["hook_event_name"] as? String, "DiffApprovalRequest")
        XCTAssertEqual(pendingDict["decision_kind"] as? String, "diff")

        let result = FeedCoordinator.shared.deliverReply(
            requestId: requestId,
            decision: .permission(.once)
        )

        XCTAssertEqual(result, .delivered(waiterSignaled: false, storeResolved: true))
        let resolvedDict = await MainActor.run {
            FeedSocketEncoding.itemDict(FeedCoordinator.shared.store.items[0])
        }
        XCTAssertEqual(resolvedDict["status"] as? String, "resolved")
        let decision = try? XCTUnwrap(resolvedDict["decision"] as? [String: Any])
        XCTAssertEqual(decision?["kind"] as? String, "permission")
        XCTAssertEqual(decision?["mode"] as? String, "once")
    }

    private static func v2Error(
        method: String,
        params: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try XCTUnwrap(String(data: requestData, encoding: .utf8), file: file, line: line)
        let raw = MainActor.assumeIsolated {
            TerminalController.shared.handleSocketLine(requestLine)
        }
        let data = try XCTUnwrap(raw.data(using: .utf8), file: file, line: line)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        XCTAssertEqual(envelope["ok"] as? Bool, false, raw, file: file, line: line)
        return try XCTUnwrap(envelope["error"] as? [String: Any], raw, file: file, line: line)
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
