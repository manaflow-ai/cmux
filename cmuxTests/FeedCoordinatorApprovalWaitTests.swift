import Foundation
import Testing
import CMUXAgentLaunch

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Feed coordinator approval waits", .serialized)
struct FeedCoordinatorApprovalWaitTests {
    @Test func approvalWaitSurfacesAttentionWithoutBecomingBlockingDecision() {
        #expect(FeedCoordinator.isNeedsInputAttentionEvent(.approvalWait))
        #expect(!FeedCoordinator.isBlockingDecisionEvent(.approvalWait))
    }

    @Test func nonBlockingApprovalWaitSurfacesNeedsInputAttentionAndClears() async {
        defer {
            Self.resetFeedCoordinatorTestHooks()
        }

        let attention = ApprovalWaitAttentionRecorder()
        let sessionId = "codex-approval-wait-test"

        await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
            FeedCoordinatorTestHooks.attentionSurfaceObserver = { event in
                attention.record(event)
            }
        }

        let approvalWait = WorkstreamEvent(
            sessionId: sessionId,
            hookEventName: .approvalWait,
            source: "codex",
            workspaceId: UUID().uuidString,
            cwd: "/tmp",
            toolName: "shell",
            toolInputJSON: #"{"command":"touch /tmp/x"}"#,
            requestId: "codex-approval-wait-request"
        )

        guard case .acknowledged = FeedCoordinator.shared.ingestBlocking(
            event: approvalWait,
            waitTimeout: 0
        ) else {
            Issue.record("non-blocking approval waits should only acknowledge feed.push")
            return
        }
        await MainActor.run {}

        #expect(
            attention.events.map(\.hookEventName) == [.approvalWait],
            "a non-blocking Codex approval wait must still request in-app needs-input attention"
        )

        let inserted = await MainActor.run {
            FeedCoordinator.shared.store.items.first
        }
        #expect(inserted?.kind == .approvalWait)
        #expect(inserted?.status.isPending == true)

        _ = FeedCoordinator.shared.ingestBlocking(
            event: WorkstreamEvent(
                sessionId: sessionId,
                hookEventName: .postToolUse,
                source: "codex",
                cwd: "/tmp",
                toolName: "shell",
                toolInputJSON: #"{"exitcode":0}"#
            ),
            waitTimeout: 0
        )
        await MainActor.run {}

        let clearedStatus = await MainActor.run {
            FeedCoordinator.shared.store.items.first?.status
        }
        if case .cleared = clearedStatus {
            return
        }
        Issue.record("expected next same-session Codex event to clear approval wait")
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
}

private final class ApprovalWaitAttentionRecorder: @unchecked Sendable {
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
