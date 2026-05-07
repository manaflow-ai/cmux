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

    func testNotificationSuppressedWhenReplyArrivesFast() async {
        let notificationFired = DispatchSemaphore(value: 0)
        let coordinator = FeedCoordinator(
            notificationPoster: { _, _ in notificationFired.signal() },
            notificationGraceDelay: 0.3
        )
        await MainActor.run {
            coordinator.install(store: WorkstreamStore(ringCapacity: 10))
        }

        let event = WorkstreamEvent(
            sessionId: "notif-suppress-test",
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: "Bash",
            toolInputJSON: #"{"command":"true"}"#,
            requestId: "notif-suppress-request"
        )

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = coordinator.ingestBlocking(event: event, waitTimeout: 5)
            done.signal()
        }

        // Reply well within the grace period — notification should be suppressed.
        Thread.sleep(forTimeInterval: 0.05)
        coordinator.deliverReply(requestId: "notif-suppress-request", decision: .permission(.once))

        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(notificationFired.wait(timeout: .now() + 0.5), .timedOut,
            "notification should be suppressed when reply arrives before grace period")
    }

    func testNotificationFiresWhenNoReplyArrives() async {
        let notificationFired = DispatchSemaphore(value: 0)
        let coordinator = FeedCoordinator(
            notificationPoster: { _, _ in notificationFired.signal() },
            notificationGraceDelay: 0.1
        )
        await MainActor.run {
            coordinator.install(store: WorkstreamStore(ringCapacity: 10))
        }

        let event = WorkstreamEvent(
            sessionId: "notif-fire-test",
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: "Bash",
            toolInputJSON: #"{"command":"true"}"#,
            requestId: "notif-fire-request"
        )

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = coordinator.ingestBlocking(event: event, waitTimeout: 2)
            done.signal()
        }

        // No reply — notification should fire after the grace period.
        XCTAssertEqual(notificationFired.wait(timeout: .now() + 1), .success,
            "notification should fire when no reply arrives within grace period")

        // Unblock ingestBlocking and wait for it to finish.
        coordinator.deliverReply(requestId: "notif-fire-request", decision: .permission(.once))
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
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

        let done = DispatchSemaphore(value: 0)
        let resultBox = IngestResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            resultBox.value = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 0.05
            )
            done.signal()
        }

        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)

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
}

private final class IngestResultBox: @unchecked Sendable {
    var value: FeedCoordinator.IngestBlockingResult?
}
