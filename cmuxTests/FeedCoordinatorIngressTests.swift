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
        let ordinaryPendingCapacity = 24
        let attemptedBacklogCount = 32
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
        #expect(acceptedBacklogSessionIds.count == ordinaryPendingCapacity)
        #expect(rejectedBacklogSessionIds.count == attemptedBacklogCount - ordinaryPendingCapacity)

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

    @Test func sessionCriticalZeroWaitUsesReservedCapacityAfterOrdinarySaturation() async {
        await MainActor.run {
            FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 100))
        }
        let firstDeliveryStarted = DispatchSemaphore(value: 0)
        let releaseFirstDelivery = DispatchSemaphore(value: 0)
        let ordinaryDeliveryFinished = DispatchSemaphore(value: 0)
        let sessionCriticalDeliveryFinished = DispatchSemaphore(value: 0)
        let ordinaryPendingCapacity = 24
        defer { releaseFirstDelivery.signal() }

        let firstEvent = WorkstreamEvent(
            sessionId: "pi-session-critical-reserve-active",
            hookEventName: .postToolUse,
            source: "pi",
            requestId: "pi-session-critical-reserve-active-request"
        )
        guard case .acknowledged(itemId: nil) = FeedCoordinator.shared.ingestBlocking(
            event: firstEvent,
            waitTimeout: 0,
            onAccepted: { _ in
                firstDeliveryStarted.signal()
                releaseFirstDelivery.wait()
            }
        ) else {
            Issue.record("first zero-wait Feed event was not admitted")
            return
        }
        #expect(firstDeliveryStarted.wait(timeout: .now() + 1) == .success)

        var admittedOrdinaryCount = 0
        var rejectedOrdinaryCount = 0
        for index in 0..<32 {
            let event = WorkstreamEvent(
                sessionId: "pi-session-critical-reserve-ordinary-\(index)",
                hookEventName: .postToolUse,
                source: "pi",
                requestId: "pi-session-critical-reserve-ordinary-request-\(index)"
            )
            switch FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 0,
                onAccepted: { _ in ordinaryDeliveryFinished.signal() }
            ) {
            case .acknowledged(itemId: nil):
                admittedOrdinaryCount += 1
            case .unavailable:
                rejectedOrdinaryCount += 1
            default:
                Issue.record("ordinary zero-wait admission returned an unexpected result")
            }
        }
        #expect(admittedOrdinaryCount == ordinaryPendingCapacity)
        #expect(rejectedOrdinaryCount == 32 - ordinaryPendingCapacity)

        let ordinaryLifecycleTelemetryEventNames: [WorkstreamEvent.HookEventName] = [
            .preCompact,
            .postCompact,
            .subagentStart,
            .subagentStop,
        ]
        for eventName in ordinaryLifecycleTelemetryEventNames {
            let event = WorkstreamEvent(
                sessionId: "pi-session-critical-reserve-ordinary-\(eventName.rawValue)",
                hookEventName: eventName,
                source: "pi",
                requestId: "pi-session-critical-reserve-ordinary-request-\(eventName.rawValue)"
            )
            let result = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 0
            )
            guard case .unavailable = result else {
                Issue.record("\(eventName.rawValue) consumed session-critical reserve capacity")
                continue
            }
        }

        let sessionCriticalEventNames: [WorkstreamEvent.HookEventName] = [
            .sessionStart,
            .userPromptSubmit,
            .stop,
            .sessionEnd,
            .permissionRequest,
            .askUserQuestion,
            .exitPlanMode,
            .notification,
        ]
        var admittedSessionCriticalCount = 0
        for eventName in sessionCriticalEventNames {
            let event = WorkstreamEvent(
                sessionId: "pi-session-critical-reserve-\(eventName.rawValue)",
                hookEventName: eventName,
                source: "pi",
                requestId: "pi-session-critical-reserve-request-\(eventName.rawValue)"
            )
            guard case .acknowledged(itemId: nil) = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 0,
                onAccepted: { _ in sessionCriticalDeliveryFinished.signal() }
            ) else {
                Issue.record("\(eventName.rawValue) did not use session-critical reserve capacity")
                continue
            }
            admittedSessionCriticalCount += 1
        }
        guard admittedSessionCriticalCount == sessionCriticalEventNames.count else {
            releaseFirstDelivery.signal()
            for _ in 0..<admittedOrdinaryCount {
                _ = ordinaryDeliveryFinished.wait(timeout: .now() + 2)
            }
            return
        }

        releaseFirstDelivery.signal()
        for _ in sessionCriticalEventNames {
            #expect(sessionCriticalDeliveryFinished.wait(timeout: .now() + 2) == .success)
        }
        for _ in 0..<admittedOrdinaryCount {
            #expect(ordinaryDeliveryFinished.wait(timeout: .now() + 2) == .success)
        }
    }

    @Test func acknowledgedBatchWaitsForEarlierSameSessionZeroWait() async {
        await MainActor.run {
            FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 10))
        }
        let deliveries = AttentionSurfaceRecorder()
        let firstDeliveryStarted = DispatchSemaphore(value: 0)
        let releaseFirstDelivery = DispatchSemaphore(value: 0)
        let zeroWaitFinished = DispatchSemaphore(value: 0)
        let batchSubmissionStarted = DispatchSemaphore(value: 0)
        let batchFinished = DispatchSemaphore(value: 0)
        defer { releaseFirstDelivery.signal() }

        let unrelatedEvent = WorkstreamEvent(
            sessionId: "pi-chronology-unrelated",
            hookEventName: .postToolUse,
            source: "pi",
            requestId: "pi-chronology-unrelated-request"
        )
        _ = FeedCoordinator.shared.ingestBlocking(
            event: unrelatedEvent,
            waitTimeout: 0,
            onAccepted: { _ in
                firstDeliveryStarted.signal()
                releaseFirstDelivery.wait()
            }
        )
        #expect(firstDeliveryStarted.wait(timeout: .now() + 1) == .success)

        let zeroWaitEvent = WorkstreamEvent(
            sessionId: "pi-chronology-shared",
            hookEventName: .postToolUse,
            source: "pi",
            requestId: "pi-chronology-zero-wait-request"
        )
        guard case .acknowledged(itemId: nil) = FeedCoordinator.shared.ingestBlocking(
            event: zeroWaitEvent,
            waitTimeout: 0,
            onAccepted: { event in
                deliveries.record(event)
                zeroWaitFinished.signal()
            }
        ) else {
            Issue.record("same-session zero-wait event was not admitted")
            return
        }

        let batchEvent = WorkstreamEvent(
            sessionId: zeroWaitEvent.sessionId,
            hookEventName: .postToolUse,
            source: zeroWaitEvent.source,
            requestId: "pi-chronology-batch-request"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            batchSubmissionStarted.signal()
            _ = TerminalController.shared.v2IngestAcknowledgedFeedEvents([batchEvent])
            deliveries.record(batchEvent)
            batchFinished.signal()
        }

        #expect(batchSubmissionStarted.wait(timeout: .now() + 1) == .success)
        releaseFirstDelivery.signal()
        #expect(zeroWaitFinished.wait(timeout: .now() + 2) == .success)
        #expect(batchFinished.wait(timeout: .now() + 2) == .success)
        #expect(
            deliveries.events.map(\.requestId) == [zeroWaitEvent.requestId, batchEvent.requestId],
            "same-session Feed chronology must survive cross-class scheduling"
        )
    }
}
