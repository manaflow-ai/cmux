import Foundation
import Testing
import CMUXAgentLaunch

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension FeedCoordinatorTests {
    @Test func zeroWaitBacklogIsBoundedFIFOAndYieldsToAcknowledgedIngress() async {
        await MainActor.run {
            FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 100))
        }
        let deliveries = AttentionSurfaceRecorder()
        let backlogDeliveries = AttentionSurfaceRecorder()
        let firstDeliveryStarted = DispatchSemaphore(value: 0)
        let releaseFirstDelivery = DispatchSemaphore(value: 0)
        let backlogDeliveryFinished = DispatchSemaphore(value: 0)
        let batchSubmissionStarted = DispatchSemaphore(value: 0)
        let batchFinished = DispatchSemaphore(value: 0)
        let pendingCapacity = 32
        let attemptedBacklogCount = 40
        defer { releaseFirstDelivery.signal() }

        let firstEvent = WorkstreamEvent(
            sessionId: "pi-bounded-ingress-first",
            hookEventName: .postToolUse,
            source: "pi",
            requestId: "pi-bounded-ingress-first-request"
        )
        let firstResult = FeedCoordinator.shared.ingestBlocking(
            event: firstEvent,
            waitTimeout: 0,
            onAccepted: { event in
                firstDeliveryStarted.signal()
                releaseFirstDelivery.wait()
                deliveries.record(event)
            }
        )
        guard case .acknowledged(itemId: nil) = firstResult else {
            Issue.record("first zero-wait Feed event was not admitted")
            return
        }
        #expect(firstDeliveryStarted.wait(timeout: .now() + 1) == .success)

        var acceptedBacklogSessionIds: [String] = []
        var rejectedBacklogSessionIds: [String] = []
        for index in 0..<attemptedBacklogCount {
            let sessionId = "pi-bounded-ingress-backlog-\(index)"
            let event = WorkstreamEvent(
                sessionId: sessionId,
                hookEventName: .postToolUse,
                source: "pi",
                requestId: "pi-bounded-ingress-backlog-request-\(index)"
            )
            let result = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 0,
                onAccepted: { event in
                    backlogDeliveries.record(event)
                    deliveries.record(event)
                    backlogDeliveryFinished.signal()
                }
            )
            switch result {
            case .acknowledged(itemId: nil):
                acceptedBacklogSessionIds.append(sessionId)
            case .unavailable:
                rejectedBacklogSessionIds.append(sessionId)
            default:
                Issue.record("zero-wait admission returned an unexpected result")
            }
        }
        #expect(acceptedBacklogSessionIds.count == pendingCapacity)
        #expect(rejectedBacklogSessionIds.count == attemptedBacklogCount - pendingCapacity)

        let batchEvent = WorkstreamEvent(
            sessionId: "pi-bounded-ingress-batch",
            hookEventName: .postToolUse,
            source: "pi",
            requestId: "pi-bounded-ingress-batch-request"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            batchSubmissionStarted.signal()
            _ = TerminalController.shared.v2IngestAcknowledgedFeedEvents([batchEvent])
            deliveries.record(batchEvent)
            batchFinished.signal()
        }

        #expect(batchSubmissionStarted.wait(timeout: .now() + 1) == .success)
        releaseFirstDelivery.signal()
        #expect(batchFinished.wait(timeout: .now() + 2) == .success)

        for _ in acceptedBacklogSessionIds {
            guard backlogDeliveryFinished.wait(timeout: .now() + 2) == .success else {
                Issue.record("an admitted zero-wait Feed event was not delivered")
                break
            }
        }
        let deliveredBacklogSessionIds = backlogDeliveries.events.map(\.sessionId)
        #expect(
            deliveredBacklogSessionIds == acceptedBacklogSessionIds,
            "admitted zero-wait Feed events must be delivered exactly once in FIFO order"
        )
        #expect(
            rejectedBacklogSessionIds.allSatisfy { !deliveredBacklogSessionIds.contains($0) },
            "zero-wait Feed events rejected at capacity must never be delivered"
        )

        let deliverySessionIds = deliveries.events.map(\.sessionId)
        guard let batchIndex = deliverySessionIds.firstIndex(of: batchEvent.sessionId) else {
            Issue.record("acknowledged Feed ingress did not finish")
            return
        }
        #expect(
            batchIndex <= 2,
            "acknowledged Feed ingress must interleave before the pending telemetry backlog drains"
        )
    }
}
