import Foundation
import Testing
import CMUXAgentLaunch

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension FeedCoordinatorTests {
    @Test func synchronousDeliveryBacklogIsBounded() {
        let lane = FeedIngressDeliveryLane()
        let activeDeliveryStarted = DispatchSemaphore(value: 0)
        let releaseActiveDelivery = DispatchSemaphore(value: 0)
        let submissionReady = DispatchSemaphore(value: 0)
        let releaseSubmissions = DispatchSemaphore(value: 0)
        let submissionReturned = DispatchSemaphore(value: 0)
        defer {
            releaseActiveDelivery.signal()
            for _ in 0..<33 {
                releaseSubmissions.signal()
            }
        }

        let activeAccepted = lane.enqueueZeroWait(
            metadata: FeedIngressDeliveryMetadata(
                keys: [FeedIngressDeliveryKey(source: "pi", sessionId: "active")],
                importance: .ordinary
            )
        ) { _ in
            activeDeliveryStarted.signal()
            releaseActiveDelivery.wait()
        }
        #expect(activeAccepted)
        #expect(activeDeliveryStarted.wait(timeout: .now() + 1) == .success)

        for _ in 0..<33 {
            Thread.detachNewThread {
                submissionReady.signal()
                releaseSubmissions.wait()
                _ = lane.perform(
                    metadata: FeedIngressDeliveryMetadata(
                        keys: [
                            FeedIngressDeliveryKey(
                                source: "pi",
                                sessionId: "active"
                            )
                        ],
                        importance: .acknowledged
                    ),
                    timeout: 2
                ) { result in
                    _ = result.commit { true }
                }
                submissionReturned.signal()
            }
        }
        for _ in 0..<33 {
            #expect(submissionReady.wait(timeout: .now() + 1) == .success)
        }
        for _ in 0..<33 {
            releaseSubmissions.signal()
        }

        #expect(
            submissionReturned.wait(timeout: .now() + 0.5) == .success,
            "one synchronous submission must be rejected at bounded capacity"
        )
        releaseActiveDelivery.signal()
        for _ in 0..<32 {
            #expect(submissionReturned.wait(timeout: .now() + 2) == .success)
        }
    }

    @Test func synchronousDeliveryTimeoutCancelsRunningDeliveryBeforeCommit() {
        let lane = FeedIngressDeliveryLane()
        let deliveryStarted = DispatchSemaphore(value: 0)
        let releaseDelivery = DispatchSemaphore(value: 0)
        let deliveryFinished = DispatchSemaphore(value: 0)
        let commitRejected = DispatchSemaphore(value: 0)
        let callerTimedOut = DispatchSemaphore(value: 0)
        let callerReturned = DispatchSemaphore(value: 0)
        defer { releaseDelivery.signal() }

        let metadata = FeedIngressDeliveryMetadata(
            keys: [
                FeedIngressDeliveryKey(
                    source: "pi",
                    sessionId: "pi-bounded-synchronous-delivery"
                )
            ],
            importance: .acknowledged
        )
        CLITestProcessRunner.detachBlockingThread(name: "cmux-test-FeedCoordinatorIngressTests") {
            let value = lane.perform(metadata: metadata, timeout: 0.05) { result in
                deliveryStarted.signal()
                releaseDelivery.wait()
                guard result.commit({
                    deliveryFinished.signal()
                    return true
                }) != nil else {
                    commitRejected.signal()
                    return
                }
            }
            if value == nil {
                callerTimedOut.signal()
            }
            callerReturned.signal()
        }

        #expect(deliveryStarted.wait(timeout: .now() + 1) == .success)
        #expect(callerReturned.wait(timeout: .now() + 1) == .success)
        #expect(callerTimedOut.wait(timeout: .now()) == .success)
        #expect(deliveryFinished.wait(timeout: .now()) == .timedOut)

        releaseDelivery.signal()
        #expect(commitRejected.wait(timeout: .now() + 1) == .success)
        #expect(deliveryFinished.wait(timeout: .now()) == .timedOut)
    }

    @Test func committedDeliveryReturnsAtDeadlineWhenPublicationStalls() async {
        let lane = FeedIngressDeliveryLane()
        let mutationCommitted = DispatchSemaphore(value: 0)
        let releasePublication = DispatchSemaphore(value: 0)
        let publicationFinished = DispatchSemaphore(value: 0)
        let callerReturned = DispatchSemaphore(value: 0)
        defer { releasePublication.signal() }

        let metadata = FeedIngressDeliveryMetadata(
            keys: [
                FeedIngressDeliveryKey(
                    source: "pi",
                    sessionId: "pi-committed-publication-order"
                )
            ],
            importance: .acknowledged
        )
        let resultTask = Task.detached {
            let value = lane.perform(metadata: metadata, timeout: 0.05) { result in
                _ = result.commit {
                    mutationCommitted.signal()
                    return true
                }
                releasePublication.wait()
                publicationFinished.signal()
            }
            callerReturned.signal()
            return value
        }

        #expect(mutationCommitted.wait(timeout: .now() + 1) == .success)
        let returnedBeforePublicationReleased = callerReturned.wait(timeout: .now() + 1)
        #expect(
            returnedBeforePublicationReleased == .success,
            "a committed mutation must not pin socket ingress behind stalled publication"
        )
        releasePublication.signal()
        if returnedBeforePublicationReleased != .success {
            #expect(callerReturned.wait(timeout: .now() + 1) == .success)
        }
        #expect(await resultTask.value == true)
        #expect(publicationFinished.wait(timeout: .now() + 1) == .success)
    }

    @Test func positiveTimeoutAcceptanceCallbackCompletesBeforeAcknowledgedCallerReturns() async {
        await MainActor.run {
            FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 10))
        }
        let callbackStarted = DispatchSemaphore(value: 0)
        let callbackRanOffMain = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let callerReturned = DispatchSemaphore(value: 0)
        defer { releaseCallback.signal() }
        let event = WorkstreamEvent(
            sessionId: "pi-positive-timeout-publication-order",
            hookEventName: .postToolUse,
            source: "pi"
        )

        let resultTask = Task.detached {
            let result = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 2,
                onAccepted: { _ in
                    if !Thread.isMainThread {
                        callbackRanOffMain.signal()
                    }
                    callbackStarted.signal()
                    releaseCallback.wait()
                }
            )
            callerReturned.signal()
            return result
        }

        #expect(callbackStarted.wait(timeout: .now() + 1) == .success)
        #expect(
            callbackRanOffMain.wait(timeout: .now()) == .success,
            "nonisolated Feed publication must not run on the main thread"
        )
        #expect(
            callerReturned.wait(timeout: .now() + 0.2) == .timedOut,
            "the synchronous caller must not return before accepted-event publication finishes"
        )
        releaseCallback.signal()
        #expect(callerReturned.wait(timeout: .now() + 1) == .success)
        guard case .acknowledged = await resultTask.value else {
            Issue.record("positive-timeout Feed ingress did not acknowledge the accepted event")
            return
        }
    }

    @Test func positiveTimeoutReturnsAuthoritativeEventWhenMainActorCallbackStalls() async {
        await MainActor.run {
            FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 10))
        }
        let callbackStarted = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let callbackFinished = DispatchSemaphore(value: 0)
        let callerReturned = DispatchSemaphore(value: 0)
        defer { releaseCallback.signal() }
        let event = WorkstreamEvent(
            sessionId: "pi-positive-timeout-publication-order",
            hookEventName: .postToolUse,
            source: "pi"
        )

        let resultTask = Task.detached {
            let outcome = FeedCoordinator.shared.ingestBlockingWithOutcome(
                event: event,
                waitTimeout: 0.05,
                onAcceptedOnMainActor: { _ in
                    callbackStarted.signal()
                    _ = releaseCallback.wait(timeout: .now() + 2)
                    callbackFinished.signal()
                }
            )
            callerReturned.signal()
            return outcome
        }

        #expect(callbackStarted.wait(timeout: .now() + 1) == .success)
        let returnedAtDeadline = callerReturned.wait(timeout: .now() + 1)
        if returnedAtDeadline != .success {
            // Keep the pre-fix failure bounded: release the callback so the
            // task can finish after the failed deadline assertion.
            releaseCallback.signal()
        }
        #expect(returnedAtDeadline == .success)
        #expect(
            callbackFinished.wait(timeout: .now()) == .timedOut,
            "the authoritative outcome must not wait for a stalled main-actor callback"
        )
        let outcome = await resultTask.value
        guard case .acknowledged(let itemId) = outcome.result else {
            Issue.record("positive-timeout Feed ingress did not acknowledge the committed event")
            return
        }
        #expect(itemId != nil)
        #expect(outcome.authoritativeEvent == event)
        releaseCallback.signal()
        #expect(callbackFinished.wait(timeout: .now() + 1) == .success)
    }

    @Test func blockingAcceptanceCallbackCompletesBeforeResolvedCallerReturns() async {
        let requestId = "pi-blocking-publication-order-request"
        await MainActor.run {
            FeedCoordinator.shared.install(store: WorkstreamStore(ringCapacity: 10))
            FeedCoordinatorTestHooks.afterBlockingEventIngested = { _, ingestedRequestId in
                guard ingestedRequestId == requestId else { return }
                FeedCoordinator.shared.deliverReply(
                    requestId: ingestedRequestId,
                    decision: .permission(.once)
                )
            }
        }
        defer { Self.resetFeedCoordinatorTestHooks() }
        let callbackStarted = DispatchSemaphore(value: 0)
        let callbackRanOffMain = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let callerReturned = DispatchSemaphore(value: 0)
        defer { releaseCallback.signal() }
        let event = WorkstreamEvent(
            sessionId: "pi-blocking-publication-order",
            hookEventName: .permissionRequest,
            source: "pi",
            requestId: requestId
        )

        let resultTask = Task.detached {
            let result = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 2,
                onAccepted: { _ in
                    if !Thread.isMainThread {
                        callbackRanOffMain.signal()
                    }
                    callbackStarted.signal()
                    releaseCallback.wait()
                }
            )
            callerReturned.signal()
            return result
        }

        #expect(callbackStarted.wait(timeout: .now() + 1) == .success)
        #expect(
            callbackRanOffMain.wait(timeout: .now()) == .success,
            "blocking Feed publication must not run on the main thread"
        )
        #expect(
            callerReturned.wait(timeout: .now() + 0.2) == .timedOut,
            "completed publication must not overtake accepted-event publication"
        )
        releaseCallback.signal()
        #expect(callerReturned.wait(timeout: .now() + 1) == .success)
        guard case .resolved = await resultTask.value else {
            Issue.record("blocking Feed ingress did not return the delivered decision")
            return
        }
    }

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
        let sharedSessionId = "pi-bounded-ingress-shared"
        defer { releaseFirstDelivery.signal() }

        let firstEvent = WorkstreamEvent(
            sessionId: sharedSessionId,
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

        var acceptedBacklogRequestIds: [String] = []
        var rejectedBacklogRequestIds: [String] = []
        for index in 0..<attemptedBacklogCount {
            let requestId = "pi-bounded-ingress-backlog-request-\(index)"
            let event = WorkstreamEvent(
                sessionId: sharedSessionId,
                hookEventName: .postToolUse,
                source: "pi",
                requestId: requestId
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
                acceptedBacklogRequestIds.append(requestId)
            case .unavailable:
                rejectedBacklogRequestIds.append(requestId)
            default:
                Issue.record("zero-wait admission returned an unexpected result")
            }
        }
        #expect(acceptedBacklogRequestIds.count == ordinaryPendingCapacity)
        #expect(rejectedBacklogRequestIds.count == attemptedBacklogCount - ordinaryPendingCapacity)

        let batchEvent = WorkstreamEvent(
            sessionId: "pi-bounded-ingress-batch",
            hookEventName: .postToolUse,
            source: "pi",
            requestId: "pi-bounded-ingress-batch-request"
        )
        CLITestProcessRunner.detachBlockingThread(name: "cmux-test-FeedCoordinatorIngressTests") {
            batchSubmissionStarted.signal()
            _ = TerminalController.shared.v2IngestAcknowledgedFeedEvents([batchEvent])
            deliveries.record(batchEvent)
            batchFinished.signal()
        }

        #expect(batchSubmissionStarted.wait(timeout: .now() + 1) == .success)
        let batchCompletedWhileSharedSessionStalled = batchFinished.wait(timeout: .now() + 2)
        releaseFirstDelivery.signal()
        if batchCompletedWhileSharedSessionStalled != .success {
            #expect(batchFinished.wait(timeout: .now() + 2) == .success)
        }
        #expect(
            batchCompletedWhileSharedSessionStalled == .success,
            "acknowledged Feed ingress on another session must bypass a stalled session"
        )

        for _ in acceptedBacklogRequestIds {
            guard backlogDeliveryFinished.wait(timeout: .now() + 2) == .success else {
                Issue.record("an admitted zero-wait Feed event was not delivered")
                break
            }
        }
        let deliveredBacklogRequestIds = backlogDeliveries.events.compactMap(\.requestId)
        #expect(
            deliveredBacklogRequestIds == acceptedBacklogRequestIds,
            "admitted zero-wait Feed events must be delivered exactly once in FIFO order"
        )
        #expect(
            rejectedBacklogRequestIds.allSatisfy { !deliveredBacklogRequestIds.contains($0) },
            "zero-wait Feed events rejected at capacity must never be delivered"
        )
        #expect(deliveries.events.contains { $0.requestId == batchEvent.requestId })
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
        let sharedSessionId = "pi-session-critical-reserve"
        defer { releaseFirstDelivery.signal() }

        let firstEvent = WorkstreamEvent(
            sessionId: sharedSessionId,
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
                sessionId: sharedSessionId,
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
                sessionId: sharedSessionId,
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
                sessionId: sharedSessionId,
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

        let overflowSessionCriticalStarted = DispatchSemaphore(value: 0)
        let overflowSessionCriticalReturned = DispatchSemaphore(value: 0)
        let overflowSessionCriticalDelivered = DispatchSemaphore(value: 0)
        let overflowSessionCriticalEvent = WorkstreamEvent(
            sessionId: sharedSessionId,
            hookEventName: .notification,
            source: "pi",
            requestId: "pi-session-critical-overflow-request"
        )
        let overflowSessionCriticalTask = Task.detached {
            overflowSessionCriticalStarted.signal()
            let result = FeedCoordinator.shared.ingestBlocking(
                event: overflowSessionCriticalEvent,
                waitTimeout: 0,
                onAccepted: { _ in overflowSessionCriticalDelivered.signal() }
            )
            overflowSessionCriticalReturned.signal()
            return result
        }
        #expect(overflowSessionCriticalStarted.wait(timeout: .now() + 1) == .success)
        let returnedWhileSaturated = overflowSessionCriticalReturned.wait(timeout: .now() + 0.1)
        #expect(
            returnedWhileSaturated == .timedOut,
            "session-critical overflow must backpressure instead of returning unavailable"
        )

        releaseFirstDelivery.signal()
        if returnedWhileSaturated == .timedOut {
            #expect(overflowSessionCriticalReturned.wait(timeout: .now() + 2) == .success)
        }
        let overflowSessionCriticalResult = await overflowSessionCriticalTask.value
        guard case .acknowledged(itemId: nil) = overflowSessionCriticalResult else {
            Issue.record("session-critical overflow was dropped while ordinary telemetry remained queued")
            for _ in sessionCriticalEventNames {
                _ = sessionCriticalDeliveryFinished.wait(timeout: .now() + 2)
            }
            for _ in 0..<admittedOrdinaryCount {
                _ = ordinaryDeliveryFinished.wait(timeout: .now() + 2)
            }
            return
        }
        #expect(overflowSessionCriticalDelivered.wait(timeout: .now() + 2) == .success)
        for _ in sessionCriticalEventNames {
            #expect(sessionCriticalDeliveryFinished.wait(timeout: .now() + 2) == .success)
        }
        for _ in 0..<admittedOrdinaryCount {
            #expect(ordinaryDeliveryFinished.wait(timeout: .now() + 2) == .success)
        }
    }

    @Test func acknowledgedBatchPreservesSameSessionOrderWhileUnrelatedDeliveryStalls() async {
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
        CLITestProcessRunner.detachBlockingThread(name: "cmux-test-FeedCoordinatorIngressTests") {
            batchSubmissionStarted.signal()
            _ = TerminalController.shared.v2IngestAcknowledgedFeedEvents([batchEvent])
            deliveries.record(batchEvent)
            batchFinished.signal()
        }

        #expect(batchSubmissionStarted.wait(timeout: .now() + 1) == .success)
        let zeroWaitCompletedWhileUnrelatedStalled = zeroWaitFinished.wait(timeout: .now() + 0.5)
        let batchCompletedWhileUnrelatedStalled = batchFinished.wait(timeout: .now() + 0.5)
        releaseFirstDelivery.signal()
        if zeroWaitCompletedWhileUnrelatedStalled != .success {
            #expect(zeroWaitFinished.wait(timeout: .now() + 2) == .success)
        }
        if batchCompletedWhileUnrelatedStalled != .success {
            #expect(batchFinished.wait(timeout: .now() + 2) == .success)
        }
        #expect(
            zeroWaitCompletedWhileUnrelatedStalled == .success,
            "an unrelated stalled delivery must not block zero-wait Feed ingress"
        )
        #expect(
            batchCompletedWhileUnrelatedStalled == .success,
            "an unrelated stalled delivery must not exhaust acknowledged Feed ingress"
        )
        #expect(
            deliveries.events.map(\.requestId) == [zeroWaitEvent.requestId, batchEvent.requestId],
            "same-session Feed chronology must survive cross-class scheduling"
        )
    }
}
