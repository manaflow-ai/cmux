import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Port scan publication lifecycle")
struct PortScanPublicationStateTests {
    @Test("A newer lifecycle revision rejects a queued stale publication")
    func staleRevisionIsRejected() {
        let state = PortScanPublicationState()
        let workspaceID = UUID()
        let staleRevision = state.nextAgentRevision(for: workspaceID)
        let currentRevision = state.nextAgentRevision(for: workspaceID)
        let stalePublication = AgentPortScanPublication(
            workspaceId: workspaceID,
            ports: [4000],
            revision: staleRevision,
            requestID: 1,
            removesLifecycle: false
        )
        let currentPublication = AgentPortScanPublication(
            workspaceId: workspaceID,
            ports: [4200],
            revision: currentRevision,
            requestID: 2,
            removesLifecycle: false
        )

        let accepted = state.acceptCurrentAgentPublications([stalePublication, currentPublication])

        #expect(accepted == [currentPublication])
    }

    @Test("Finishing a one-shot lifecycle removes only its current revision")
    func oneShotLifecycleRemovalIsRevisionGated() {
        let state = PortScanPublicationState()
        let workspaceID = UUID()
        let staleRevision = state.nextAgentRevision(for: workspaceID)
        let currentRevision = state.nextAgentRevision(for: workspaceID)

        state.finishAgentLifecycle(workspaceId: workspaceID, revision: staleRevision)
        #expect(state.isCurrentAgentRevision(currentRevision, workspaceId: workspaceID))

        state.finishAgentLifecycle(workspaceId: workspaceID, revision: currentRevision)
        #expect(state.isCurrentAgentRevision(currentRevision, workspaceId: workspaceID) == false)

        let restartedRevision = state.nextAgentRevision(for: workspaceID)
        #expect(restartedRevision > currentRevision)
        #expect(state.isCurrentAgentRevision(currentRevision, workspaceId: workspaceID) == false)
        #expect(state.isCurrentAgentRevision(restartedRevision, workspaceId: workspaceID))
    }

    @Test("Explicit workspace invalidation rejects every queued lifecycle value")
    func workspaceInvalidationRejectsQueuedPublication() {
        let state = PortScanPublicationState()
        let workspaceID = UUID()
        let revision = state.nextAgentRevision(for: workspaceID)
        let publication = AgentPortScanPublication(
            workspaceId: workspaceID,
            ports: [4200],
            revision: revision,
            requestID: 1,
            removesLifecycle: false
        )

        let invalidatingRevision = state.invalidateAgentLifecycle(for: workspaceID)
        let accepted = state.acceptCurrentAgentPublications([publication])

        #expect(invalidatingRevision > revision)
        #expect(accepted.isEmpty)
        #expect(state.isCurrentAgentRevision(revision, workspaceId: workspaceID) == false)
    }
}

@Suite("Agent port snapshot replacement")
struct AgentPortSnapshotReplacementStateTests {
    @Test("Root transitions replace on complete or after bounded incomplete scans")
    func replacementIsCompletenessBounded() {
        var state = AgentPortSnapshotReplacementState(incompleteRetentionLimit: 2)
        let workspaceID = UUID()
        state.begin(workspaceId: workspaceID)

        let first = state.workspacesToReplace(from: [workspaceID], completeness: .incomplete)
        let second = state.workspacesToReplace(from: [workspaceID], completeness: .incomplete)
        let third = state.workspacesToReplace(from: [workspaceID], completeness: .incomplete)
        #expect(first.isEmpty)
        #expect(second.isEmpty)
        #expect(third == [workspaceID])

        state.begin(workspaceId: workspaceID)
        let complete = state.workspacesToReplace(from: [workspaceID], completeness: .complete)
        #expect(complete == [workspaceID])

        state.begin(workspaceId: workspaceID)
        state.cancel(workspaceId: workspaceID)
        let cancelled = state.workspacesToReplace(from: [workspaceID], completeness: .complete)
        #expect(cancelled.isEmpty)
    }
}

@Suite("Agent port tracking lifecycle")
struct AgentPortTrackingStateTests {
    @Test("Root identity changes delimit snapshots and remain available to every scan path")
    func rootIdentityChangesDelimitSnapshots() {
        var state = AgentPortTrackingState()
        let workspaceID = UUID()
        let first = AgentPortRootIdentity(
            pid: 100,
            processIdentity: AgentPIDProcessIdentity(pid: 100, startSeconds: 1, startMicroseconds: 0)
        )
        let recycledPID = AgentPortRootIdentity(
            pid: 100,
            processIdentity: AgentPIDProcessIdentity(pid: 100, startSeconds: 2, startMicroseconds: 0)
        )

        let initial = state.replaceRoots([first], workspaceId: workspaceID)
        let repeated = state.replaceRoots([first], workspaceId: workspaceID)
        let captured = state.roots(for: [workspaceID])
        let recycled = state.replaceRoots([recycledPID], workspaceId: workspaceID)
        let stopped = state.replaceRoots([], workspaceId: workspaceID)
        let repeatedStop = state.replaceRoots([], workspaceId: workspaceID)
        let restarted = state.replaceRoots([first], workspaceId: workspaceID)

        #expect(initial)
        #expect(repeated == false)
        #expect(captured == [workspaceID: [first]])
        #expect(recycled)
        #expect(stopped)
        #expect(repeatedStop == false)
        #expect(restarted)
    }
}

@Suite("Agent port publication history")
struct AgentPortPublicationHistoryTests {
    @Test("Acknowledging an older delivery preserves the newer pending request")
    func olderAcknowledgementPreservesNewerRequest() {
        var history = AgentPortPublicationHistory()
        let workspaceID = UUID()

        let initial = history.shouldPublish(
            workspaceId: workspaceID,
            ports: [4200],
            requestID: 1,
            forced: false
        )
        let newerPending = history.shouldPublish(
            workspaceId: workspaceID,
            ports: [5173],
            requestID: 2,
            forced: false
        )
        history.acknowledge(workspaceId: workspaceID, ports: [4200], requestID: 1)
        let pendingStillPublishes = history.shouldPublish(
            workspaceId: workspaceID,
            ports: [5173],
            requestID: 3,
            forced: false
        )
        history.acknowledge(workspaceId: workspaceID, ports: [5173], requestID: 3)
        let acknowledgedIsDeduplicated = history.shouldPublish(
            workspaceId: workspaceID,
            ports: [5173],
            requestID: 4,
            forced: false
        )

        #expect(initial)
        #expect(newerPending)
        #expect(pendingStillPublishes)
        #expect(acknowledgedIsDeduplicated == false)
    }
}

@Suite("Port scan publication buffer")
struct PortScanPublicationBufferTests {
    @Test("Repeated panel updates retain only the latest value behind one drain")
    func panelUpdatesAreBoundedAndCoalesced() throws {
        var buffer = PortScanPublicationBuffer()
        let key = PortScanner.PanelKey(workspaceId: UUID(), panelId: UUID())
        let removedKey = PortScanner.PanelKey(workspaceId: UUID(), panelId: UUID())

        let didScheduleInitialDrain = buffer.enqueue(
            panelPortsByKey: [key: [4000], removedKey: [5000]]
        )
        #expect(didScheduleInitialDrain)
        for port in 4001...4100 {
            let didScheduleAnotherDrain = buffer.enqueue(panelPortsByKey: [key: [port]])
            #expect(didScheduleAnotherDrain == false)
        }
        #expect(buffer.isDrainScheduled)

        let pendingBatch = buffer.takePendingBatch()
        let batch = try #require(pendingBatch)
        #expect(batch.panelPortsByKey[key] == [4100])
        #expect(batch.panelPortsByKey[removedKey] == nil)
        let emptyBatch = buffer.takePendingBatch()
        #expect(emptyBatch == nil)
        #expect(buffer.isDrainScheduled == false)
    }

    @Test("A claimed delivery stays ordered ahead of a newer queued value")
    func claimedDeliverySerializesNewerValue() throws {
        var buffer = PortScanPublicationBuffer()
        let workspaceID = UUID()
        let first = AgentPortScanPublication(
            workspaceId: workspaceID,
            ports: [4000],
            revision: 1,
            requestID: 1,
            removesLifecycle: false
        )
        let newestBeforeClaim = AgentPortScanPublication(
            workspaceId: workspaceID,
            ports: [4200],
            revision: 1,
            requestID: 2,
            removesLifecycle: false
        )
        let newerWhileClaimed = AgentPortScanPublication(
            workspaceId: workspaceID,
            ports: [5173],
            revision: 1,
            requestID: 3,
            removesLifecycle: true
        )

        let scheduledInitialDrain = buffer.enqueue(agentPublications: [first])
        let scheduledReplacementDrain = buffer.enqueue(agentPublications: [newestBeforeClaim])
        #expect(scheduledInitialDrain)
        #expect(scheduledReplacementDrain == false)
        let pendingClaimedBatch = buffer.takePendingBatch()
        let claimedBatch = try #require(pendingClaimedBatch)
        let claimed = try #require(claimedBatch.agentPublicationsByWorkspace[workspaceID])
        #expect(claimed == newestBeforeClaim)

        let scheduledClaimedDrain = buffer.enqueue(agentPublications: [newerWhileClaimed])
        #expect(scheduledClaimedDrain == false)
        #expect(buffer.hasPendingAgentPublication(newerThan: claimed))
        let blockedBatch = buffer.takePendingBatch()
        #expect(blockedBatch == nil)

        let completed = buffer.completeAgentDelivery([claimed])
        #expect(completed == [claimed])
        let pendingNextBatch = buffer.takePendingBatch()
        let nextBatch = try #require(pendingNextBatch)
        #expect(nextBatch.agentPublicationsByWorkspace[workspaceID] == newerWhileClaimed)
        _ = buffer.completeAgentDelivery([newerWhileClaimed])
        let emptyBatch = buffer.takePendingBatch()
        #expect(emptyBatch == nil)
        #expect(buffer.isDrainScheduled == false)
    }

    @Test("Workspace removal discards claimed and pending publications")
    func workspaceRemovalInvalidatesBufferedValues() throws {
        var buffer = PortScanPublicationBuffer()
        let workspaceID = UUID()
        let publication = AgentPortScanPublication(
            workspaceId: workspaceID,
            ports: [4200],
            revision: 1,
            requestID: 1,
            removesLifecycle: false
        )
        let didSchedule = buffer.enqueue(agentPublications: [publication])
        let pendingBatch = buffer.takePendingBatch()
        _ = try #require(pendingBatch)

        buffer.removeAgentWorkspace(workspaceID)
        let completed = buffer.completeAgentDelivery([publication])
        let emptyBatch = buffer.takePendingBatch()

        #expect(didSchedule)
        #expect(completed.isEmpty)
        #expect(emptyBatch == nil)
        #expect(buffer.isDrainScheduled == false)
    }
}
