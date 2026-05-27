import XCTest
import CMUXWorkstream

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FeedCoordinatorTests: XCTestCase {
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

    func testOpenCodePermissionNotificationBodyUsesSafeSummary() {
        let event = WorkstreamEvent(
            sessionId: "opencode-notification-permission",
            hookEventName: .permissionRequest,
            source: "opencode",
            toolName: "bash",
            toolInputJSON: #"{"permission":"bash","action":"run_command","metadata":{"input":{"command":"deploy --token super-secret"}}}"#,
            requestId: "per-opencode-rich"
        )

        XCTAssertEqual(
            FeedCoordinator.notificationBodyForTesting(event: event),
            "Shell command"
        )
    }

    func testOpenCodePlanAndQuestionNotificationBodiesUsePayloadDetails() {
        let planEvent = WorkstreamEvent(
            sessionId: "opencode-notification-plan",
            hookEventName: .exitPlanMode,
            source: "opencode",
            toolName: "plan_exit",
            toolInputJSON: ###"{"plan":"## Demo plan\n\n- Wire richer OpenCode hooks\n- Verify with a plugin harness"}"###,
            requestId: "que-opencode-plan"
        )
        XCTAssertEqual(
            FeedCoordinator.notificationBodyForTesting(event: planEvent),
            "Wire richer OpenCode hooks"
        )

        let questionEvent = WorkstreamEvent(
            sessionId: "opencode-notification-question",
            hookEventName: .askUserQuestion,
            source: "opencode",
            toolName: "question",
            toolInputJSON: #"{"questions":[{"question":"Which detail should cmux show?","options":[{"label":"Command","description":"Show the shell command"},{"label":"Path","description":"Show the file path"}]}]}"#,
            requestId: "que-opencode-rich"
        )
        XCTAssertEqual(
            FeedCoordinator.notificationBodyForTesting(event: questionEvent),
            "Which detail should cmux show?\n- Command\n- Path"
        )
    }

    func testOpenCodeStopNotificationUsesStopDetails() {
        let event = WorkstreamEvent(
            sessionId: "opencode-stop-notification",
            hookEventName: .stop,
            source: "opencode",
            toolInputJSON: #"{"reason":"Implemented the hook rendering update"}"#,
            extraFieldsJSON: #"{"surface_id":"11111111-1111-1111-1111-111111111111"}"#
        )

        XCTAssertEqual(
            FeedCoordinator.notificationBodyForTesting(event: event),
            "Implemented the hook rendering update"
        )
        let content = FeedCoordinator.basicStopNotificationForTesting(event: event)
        XCTAssertEqual(content?.title, "OpenCode completed")
        XCTAssertEqual(content?.subtitle, "Completed")
        XCTAssertEqual(content?.body, "Implemented the hook rendering update")
    }

    func testOpenCodeStopNotificationWithoutAssistantTextUsesTitleOnly() {
        let event = WorkstreamEvent(
            sessionId: "opencode-stop-notification-basic",
            hookEventName: .stop,
            source: "opencode",
            extraFieldsJSON: #"{"surface_id":"11111111-1111-1111-1111-111111111111"}"#
        )

        XCTAssertNil(FeedCoordinator.notificationBodyForTesting(event: event))
        let content = FeedCoordinator.basicStopNotificationForTesting(event: event)
        XCTAssertEqual(content?.title, "OpenCode completed")
        XCTAssertEqual(content?.subtitle, "Completed")
        XCTAssertEqual(content?.body, "")
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
