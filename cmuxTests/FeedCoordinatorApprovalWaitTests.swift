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
            FeedCoordinator.shared.needsInputAttentionRequestObserver = { event in
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
        #expect(attention.waitForCount(1, timeout: .now() + 2) == .success)

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

    @Test func blockingFollowUpClearsApprovalWaitAttentionForSameSession() async {
        let sessionId = "codex-approval-wait-before-blocking-test"
        let requestId = "codex-follow-up-blocking-request"

        defer {
            Self.resetFeedCoordinatorTestHooks()
        }

        await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
            store.ingest(WorkstreamEvent(
                sessionId: sessionId,
                hookEventName: .approvalWait,
                source: "codex",
                workspaceId: UUID().uuidString,
                cwd: "/tmp",
                toolName: "shell",
                toolInputJSON: #"{"command":"touch /tmp/x"}"#
            ))
            FeedCoordinator.shared.pendingApprovalWaitAttentionTargets[sessionId] = FeedCoordinator.AttentionTarget(
                workspaceId: UUID(),
                panelId: nil,
                statusKey: "codex"
            )
            FeedCoordinatorTestHooks.afterBlockingEventIngested = { _, ingestedRequestId in
                guard ingestedRequestId == requestId else { return }
                FeedCoordinator.shared.deliverReply(
                    requestId: ingestedRequestId,
                    decision: .permission(.once)
                )
            }
        }

        let resultBox = ApprovalWaitIngestResultBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            resultBox.value = FeedCoordinator.shared.ingestBlocking(
                event: WorkstreamEvent(
                    sessionId: sessionId,
                    hookEventName: .permissionRequest,
                    source: "codex",
                    cwd: "/tmp",
                    toolName: "shell",
                    toolInputJSON: #"{"command":"true"}"#,
                    requestId: requestId
                ),
                waitTimeout: 1
            )
            done.signal()
        }

        #expect(done.wait(timeout: .now() + 2) == .success)
        guard case .resolved(_, .permission(.once)) = resultBox.value else {
            Issue.record("expected blocking follow-up to resolve")
            return
        }

        let state = await MainActor.run {
            (
                FeedCoordinator.shared.store.items.first?.status,
                FeedCoordinator.shared.pendingApprovalWaitAttentionTargets[sessionId]
            )
        }
        if case .cleared = state.0 {
            #expect(state.1 == nil)
        } else {
            Issue.record("expected blocking same-session event to clear pending approval wait")
        }
    }

    @Test func processExitClearsApprovalWaitAttentionForExpiredSession() async {
        let sessionId = "codex-approval-wait-process-exit-test"
        let ppid = 42_424

        defer {
            Self.resetFeedCoordinatorTestHooks()
        }

        await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
            store.ingest(WorkstreamEvent(
                sessionId: sessionId,
                hookEventName: .approvalWait,
                source: "codex",
                workspaceId: UUID().uuidString,
                cwd: "/tmp",
                toolName: "shell",
                toolInputJSON: #"{"command":"touch /tmp/x"}"#,
                ppid: ppid
            ))
            FeedCoordinator.shared.pendingApprovalWaitAttentionTargets[sessionId] = FeedCoordinator.AttentionTarget(
                workspaceId: UUID(),
                panelId: nil,
                statusKey: "codex"
            )
            FeedCoordinator.shared.expireItemsForTerminatedProcess(ppid: ppid)
        }

        let state = await MainActor.run {
            (
                FeedCoordinator.shared.store.items.first?.status,
                FeedCoordinator.shared.pendingApprovalWaitAttentionTargets[sessionId]
            )
        }
        if case .expired = state.0 {
            #expect(state.1 == nil)
        } else {
            Issue.record("expected process exit to expire and clear approval wait attention")
        }
    }

    private static func resetFeedCoordinatorTestHooks() {
        let reset: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                FeedCoordinatorTestHooks.afterBlockingEventIngested = nil
                FeedCoordinatorTestHooks.isAppActiveOverride = nil
                FeedCoordinatorTestHooks.notificationPostObserver = nil
                FeedCoordinator.shared.needsInputAttentionRequestObserver = nil
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
    private let firstEvent = DispatchSemaphore(value: 0)
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
        firstEvent.signal()
    }

    func waitForCount(_ count: Int, timeout: DispatchTime) -> DispatchTimeoutResult {
        if events.count >= count {
            return .success
        }
        return firstEvent.wait(timeout: timeout)
    }
}

private final class ApprovalWaitIngestResultBox: @unchecked Sendable {
    var value: FeedCoordinator.IngestBlockingResult?
}
