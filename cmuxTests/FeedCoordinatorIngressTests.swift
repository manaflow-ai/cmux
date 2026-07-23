import Foundation
import Testing
import CMUXAgentLaunch

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension FeedCoordinatorTests {
    @Test func zeroWaitBacklogCoalescesAndYieldsToAcknowledgedIngress() async {
        await MainActor.run {
            FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 100))
        }
        let deliveries = AttentionSurfaceRecorder()
        let backlogDeliveries = AttentionSurfaceRecorder()
        let firstDeliveryStarted = DispatchSemaphore(value: 0)
        let releaseFirstDelivery = DispatchSemaphore(value: 0)
        let batchFinished = DispatchSemaphore(value: 0)
        let lastBacklogFinished = DispatchSemaphore(value: 0)
        let backlogCount = 64
        defer { releaseFirstDelivery.signal() }

        let firstEvent = WorkstreamEvent(
            sessionId: "pi-bounded-ingress-first",
            hookEventName: .postToolUse,
            source: "pi",
            requestId: "pi-bounded-ingress-first-request"
        )
        _ = FeedCoordinator.shared.ingestBlocking(
            event: firstEvent,
            waitTimeout: 0,
            onAccepted: { event in
                firstDeliveryStarted.signal()
                releaseFirstDelivery.wait()
                deliveries.record(event)
            }
        )
        #expect(firstDeliveryStarted.wait(timeout: .now() + 1) == .success)

        let lastBacklogSessionId = "pi-bounded-ingress-backlog-\(backlogCount - 1)"
        for index in 0..<backlogCount {
            let event = WorkstreamEvent(
                sessionId: "pi-bounded-ingress-backlog-\(index)",
                hookEventName: .postToolUse,
                source: "pi",
                requestId: "pi-bounded-ingress-backlog-request-\(index)"
            )
            _ = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 0,
                onAccepted: { event in
                    backlogDeliveries.record(event)
                    deliveries.record(event)
                    if event.sessionId == lastBacklogSessionId {
                        lastBacklogFinished.signal()
                    }
                }
            )
        }

        let batchEvent = WorkstreamEvent(
            sessionId: "pi-bounded-ingress-batch",
            hookEventName: .postToolUse,
            source: "pi",
            requestId: "pi-bounded-ingress-batch-request"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            _ = TerminalController.shared.v2IngestAcknowledgedFeedEvents([batchEvent])
            deliveries.record(batchEvent)
            batchFinished.signal()
        }

        releaseFirstDelivery.signal()
        #expect(batchFinished.wait(timeout: .now() + 2) == .success)
        #expect(lastBacklogFinished.wait(timeout: .now() + 2) == .success)
        #expect(
            backlogDeliveries.events.map(\.sessionId) == [lastBacklogSessionId],
            "best-effort telemetry backlog must coalesce to the latest pending event"
        )
        let deliverySessionIds = deliveries.events.map(\.sessionId)
        guard let batchIndex = deliverySessionIds.firstIndex(of: batchEvent.sessionId) else {
            Issue.record("acknowledged Feed ingress did not finish")
            return
        }
        #expect(
            batchIndex <= 2,
            "acknowledged Feed ingress must wait behind at most one coalesced telemetry event"
        )
    }
}
