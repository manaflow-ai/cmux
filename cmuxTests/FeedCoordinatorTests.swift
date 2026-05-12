import XCTest
import CMUXWorkstream
import UserNotifications

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

    func testFeedJumpResolverParsesHyphenatedAgentSource() {
        let parsed = FeedJumpResolver.parse("hermes-agent-session-with-dashes")

        XCTAssertEqual(parsed?.agent, "hermes-agent")
        XCTAssertEqual(parsed?.sessionId, "session-with-dashes")
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

    @MainActor
    func testPermissionRequestNotificationSuppressesWhenFrontmostTerminalMatches() {
        let target = FeedNotificationDispatcher.ActiveTerminalTarget(
            workspaceId: UUID(),
            surfaceId: UUID()
        )
        let event = WorkstreamEvent(
            sessionId: "claude-notif-match",
            hookEventName: .permissionRequest,
            source: "claude",
            toolName: "Bash",
            requestId: "notif-match-request"
        )

        var deliveredRequests: [UNNotificationRequest] = []

        FeedNotificationDispatcher.post(
            event: event,
            requestId: "notif-match-request",
            enqueue: { work in work() },
            frontmostContext: {
                FeedNotificationDispatcher.FrontmostContext(
                    isAppFrontmost: true,
                    activeTerminalTarget: target
                )
            },
            lookupTarget: { agent, sessionId in
                XCTAssertEqual(agent, "claude")
                XCTAssertEqual(sessionId, "notif-match")
                return FeedJumpResolver.Target(
                    workspaceId: target.workspaceId.uuidString,
                    surfaceId: target.surfaceId.uuidString
                )
            },
            deliverRequest: { deliveredRequests.append($0) }
        )

        XCTAssertTrue(deliveredRequests.isEmpty)
    }

    @MainActor
    func testPermissionRequestNotificationStillPostsWhenDifferentTerminalIsActive() {
        let eventTarget = FeedNotificationDispatcher.ActiveTerminalTarget(
            workspaceId: UUID(),
            surfaceId: UUID()
        )
        let activeTarget = FeedNotificationDispatcher.ActiveTerminalTarget(
            workspaceId: UUID(),
            surfaceId: UUID()
        )
        let event = WorkstreamEvent(
            sessionId: "claude-notif-different",
            hookEventName: .permissionRequest,
            source: "claude",
            toolName: "Bash",
            requestId: "notif-different-request"
        )

        var deliveredRequests: [UNNotificationRequest] = []

        FeedNotificationDispatcher.post(
            event: event,
            requestId: "notif-different-request",
            enqueue: { work in work() },
            frontmostContext: {
                FeedNotificationDispatcher.FrontmostContext(
                    isAppFrontmost: true,
                    activeTerminalTarget: activeTarget
                )
            },
            lookupTarget: { _, _ in
                FeedJumpResolver.Target(
                    workspaceId: eventTarget.workspaceId.uuidString,
                    surfaceId: eventTarget.surfaceId.uuidString
                )
            },
            deliverRequest: { deliveredRequests.append($0) }
        )

        XCTAssertEqual(deliveredRequests.count, 1)
        XCTAssertEqual(deliveredRequests.first?.identifier, "feed.notif-different-request")
        XCTAssertEqual(deliveredRequests.first?.content.categoryIdentifier, "CMUXFeedPermission")
    }

    @MainActor
    func testPermissionRequestNotificationStillPostsWhenAppIsNotFrontmost() {
        let target = FeedNotificationDispatcher.ActiveTerminalTarget(
            workspaceId: UUID(),
            surfaceId: UUID()
        )
        let event = WorkstreamEvent(
            sessionId: "claude-notif-background",
            hookEventName: .permissionRequest,
            source: "claude",
            toolName: "Bash",
            requestId: "notif-background-request"
        )

        var deliveredRequests: [UNNotificationRequest] = []

        FeedNotificationDispatcher.post(
            event: event,
            requestId: "notif-background-request",
            enqueue: { work in work() },
            frontmostContext: {
                FeedNotificationDispatcher.FrontmostContext(
                    isAppFrontmost: false,
                    activeTerminalTarget: target
                )
            },
            lookupTarget: { _, _ in
                FeedJumpResolver.Target(
                    workspaceId: target.workspaceId.uuidString,
                    surfaceId: target.surfaceId.uuidString
                )
            },
            deliverRequest: { deliveredRequests.append($0) }
        )

        XCTAssertEqual(deliveredRequests.count, 1)
        XCTAssertEqual(deliveredRequests.first?.identifier, "feed.notif-background-request")
    }

    @MainActor
    func testPermissionRequestNotificationResolvesTargetBeforeMainEnqueue() {
        let target = FeedNotificationDispatcher.ActiveTerminalTarget(
            workspaceId: UUID(),
            surfaceId: UUID()
        )
        let event = WorkstreamEvent(
            sessionId: "claude-notif-order",
            hookEventName: .permissionRequest,
            source: "claude",
            toolName: "Bash",
            requestId: "notif-order-request"
        )

        var didLookupBeforeEnqueue = false

        FeedNotificationDispatcher.post(
            event: event,
            requestId: "notif-order-request",
            enqueue: { work in
                XCTAssertTrue(didLookupBeforeEnqueue)
                work()
            },
            frontmostContext: {
                FeedNotificationDispatcher.FrontmostContext(
                    isAppFrontmost: true,
                    activeTerminalTarget: target
                )
            },
            lookupTarget: { _, _ in
                didLookupBeforeEnqueue = true
                return FeedJumpResolver.Target(
                    workspaceId: target.workspaceId.uuidString,
                    surfaceId: target.surfaceId.uuidString
                )
            },
            deliverRequest: { _ in
                XCTFail("matching focused terminal should suppress delivery")
            }
        )
    }
}

private final class IngestResultBox: @unchecked Sendable {
    var value: FeedCoordinator.IngestBlockingResult?
}
