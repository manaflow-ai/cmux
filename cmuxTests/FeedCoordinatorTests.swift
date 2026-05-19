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

    func testBlockingIngestExpiresWaiterWhenAgentProcessExitsBeforeNotificationDisplay() async {
#if DEBUG
        let requestId = "agent-exit-request"
        let ppid = 424_242
        let notifications = NotificationRequestRecorder()

        addTeardownBlock {
            Self.resetFeedCoordinatorTestHooks()
        }

        await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
            FeedCoordinatorTestHooks.afterBlockingEventIngested = { _, ingestedRequestId in
                guard ingestedRequestId == requestId else { return }
                FeedCoordinator.shared.debugExpirePendingItemsAndWaiters(forPpid: ppid)
            }
            FeedCoordinatorTestHooks.isAppActiveOverride = { false }
            FeedCoordinatorTestHooks.notificationPostObserver = { _, postedRequestId in
                notifications.record(postedRequestId)
            }
        }

        let event = WorkstreamEvent(
            sessionId: "claude-agent-exit-test",
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: "Bash",
            toolInputJSON: #"{"command":"true"}"#,
            requestId: requestId,
            ppid: ppid
        )

        let done = expectation(description: "blocking ingest expired after agent exit")
        let resultBox = IngestResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            resultBox.value = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 5
            )
            done.fulfill()
        }

        await fulfillment(of: [done], timeout: 2)
        await MainActor.run {}

        guard case .timedOut = resultBox.value else {
            XCTFail("expected agent-exit hook to unblock as timed out")
            return
        }

        let status = await MainActor.run {
            FeedCoordinator.shared.store.items.first?.status
        }
        guard case .expired = status else {
            XCTFail("agent-exit hook item should be expired")
            return
        }
        XCTAssertTrue(
            notifications.requestIds.isEmpty,
            "expired hook requests should not post native notifications"
        )
#else
        XCTFail("debug feed test hooks are only available in DEBUG")
#endif
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
