import CmuxCore
import CmuxFoundation
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
    private func roots(startSeconds: Int64) -> Set<AgentPortRootIdentity> {
        [AgentPortRootIdentity(
            pid: 100,
            processIdentity: AgentPIDProcessIdentity(pid: 100, startSeconds: startSeconds, startMicroseconds: 0)
        )]
    }

    @Test("A claimed panel publication is rejected after its TTY lifecycle changes")
    func staleClaimedPanelPublicationIsRejected() throws {
        let state = PortScanPublicationState()
        let key = PortScanner.PanelKey(workspaceId: UUID(), panelId: UUID())
        let staleRevision = try #require(state.replacePanelLifecycle(key: key, ttyName: "ttys001"))
        let stale = PanelPortScanPublication(key: key, ports: [4000], revision: staleRevision)
        var buffer = PortScanPublicationBuffer()
        let didEnqueue = buffer.enqueue(panelPublications: [stale])
        let pendingBatch = buffer.takePendingBatch()
        #expect(didEnqueue)
        let claimed = try #require(pendingBatch)

        let currentRevision = try #require(state.replacePanelLifecycle(key: key, ttyName: "ttys002"))
        let current = PanelPortScanPublication(key: key, ports: [], revision: currentRevision)

        #expect(state.acceptCurrentPanelPublications(claimed.panelPublicationsByKey.values).isEmpty)
        #expect(state.acceptCurrentPanelPublications([current]) == [current])
    }

    @Test("Identical roots preserve a lifecycle while recycled roots reject stale publications")
    func staleRevisionIsRejected() {
        let state = PortScanPublicationState()
        let workspaceID = UUID()
        let staleRevision = state.replaceAgentLifecycle(workspaceId: workspaceID, roots: roots(startSeconds: 1))
        let repeatedRevision = state.replaceAgentLifecycle(workspaceId: workspaceID, roots: roots(startSeconds: 1))
        let stalePublication = AgentPortScanPublication(
            workspaceId: workspaceID,
            ports: [4000],
            revision: staleRevision,
            requestID: 1,
            removesLifecycle: false
        )
        let repeatedAccepted = state.acceptCurrentAgentPublications([stalePublication])
        let currentRevision = state.replaceAgentLifecycle(workspaceId: workspaceID, roots: roots(startSeconds: 2))
        let currentPublication = AgentPortScanPublication(
            workspaceId: workspaceID,
            ports: [4200],
            revision: currentRevision,
            requestID: 2,
            removesLifecycle: false
        )

        let accepted = state.acceptCurrentAgentPublications([stalePublication, currentPublication])

        #expect(repeatedRevision == staleRevision)
        #expect(repeatedAccepted == [stalePublication])
        #expect(currentRevision > staleRevision)
        #expect(accepted == [currentPublication])
    }

    @Test("Finishing a one-shot lifecycle removes only its current revision")
    func oneShotLifecycleRemovalIsRevisionGated() {
        let state = PortScanPublicationState()
        let workspaceID = UUID()
        let staleRevision = state.replaceAgentLifecycle(workspaceId: workspaceID, roots: roots(startSeconds: 1))
        let currentRevision = state.replaceAgentLifecycle(workspaceId: workspaceID, roots: roots(startSeconds: 2))

        state.finishAgentLifecycle(workspaceId: workspaceID, revision: staleRevision)
        #expect(state.isCurrentAgentRevision(currentRevision, workspaceId: workspaceID))

        state.finishAgentLifecycle(workspaceId: workspaceID, revision: currentRevision)
        #expect(state.isCurrentAgentRevision(currentRevision, workspaceId: workspaceID) == false)

        let restartedRevision = state.replaceAgentLifecycle(workspaceId: workspaceID, roots: roots(startSeconds: 3))
        #expect(restartedRevision > currentRevision)
        #expect(state.isCurrentAgentRevision(currentRevision, workspaceId: workspaceID) == false)
        #expect(state.isCurrentAgentRevision(restartedRevision, workspaceId: workspaceID))
    }

    @Test("Explicit workspace invalidation rejects every queued lifecycle value")
    func workspaceInvalidationRejectsQueuedPublication() {
        let state = PortScanPublicationState()
        let workspaceID = UUID()
        let revision = state.replaceAgentLifecycle(workspaceId: workspaceID, roots: roots(startSeconds: 1))
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
    @MainActor
    @Test("Changing one TTY enqueues only that panel's empty lifecycle publication")
    func ttyChangePublicationIsPanelScoped() throws {
        let scanner = PortScanner()
        let workspaceID = UUID()
        let changedPanelID = UUID()
        let unchangedPanelID = UUID()
        scanner.registerTTY(workspaceId: workspaceID, panelId: changedPanelID, ttyName: "ttys001")
        scanner.registerTTY(workspaceId: workspaceID, panelId: unchangedPanelID, ttyName: "ttys002")
        scanner.queue.sync {}

        scanner.registerTTY(workspaceId: workspaceID, panelId: changedPanelID, ttyName: "ttys003")
        let batch = scanner.queue.sync { () -> PortScanPublicationBatch? in
            let batch = scanner.publicationBuffer.takePendingBatch()
            _ = scanner.publicationBuffer.takePendingBatch()
            return batch
        }
        let publication = try #require(batch?.panelPublicationsByKey[PortScanner.PanelKey(
            workspaceId: workspaceID,
            panelId: changedPanelID
        )])

        #expect(batch?.panelPublicationsByKey.count == 1)
        #expect(publication.ports.isEmpty)

        scanner.unregisterPanel(workspaceId: workspaceID, panelId: changedPanelID)
        scanner.unregisterPanel(workspaceId: workspaceID, panelId: unchangedPanelID)
        scanner.queue.sync {}
    }

    @Test("Repeated panel updates retain only the latest value behind one drain")
    func panelUpdatesAreBoundedAndCoalesced() throws {
        var buffer = PortScanPublicationBuffer()
        let key = PortScanner.PanelKey(workspaceId: UUID(), panelId: UUID())
        let removedKey = PortScanner.PanelKey(workspaceId: UUID(), panelId: UUID())
        let initial = PanelPortScanPublication(key: key, ports: [4000], revision: 1)
        let unrelated = PanelPortScanPublication(key: removedKey, ports: [5000], revision: 1)

        let didScheduleInitialDrain = buffer.enqueue(panelPublications: [initial, unrelated])
        #expect(didScheduleInitialDrain)
        for port in 4001...4100 {
            let publication = PanelPortScanPublication(
                key: key,
                ports: [port],
                revision: UInt64(port)
            )
            let didScheduleAnotherDrain = buffer.enqueue(panelPublications: [publication])
            #expect(didScheduleAnotherDrain == false)
        }
        #expect(buffer.isDrainScheduled)

        let pendingBatch = buffer.takePendingBatch()
        let batch = try #require(pendingBatch)
        #expect(batch.panelPublicationsByKey[key]?.ports == [4100])
        #expect(batch.panelPublicationsByKey[removedKey]?.ports == [5000])
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

@MainActor
@Suite("Port scanner agent publication integration")
struct PortScannerAgentPublicationIntegrationTests {
    @Test(
        "Last-root removal publishes empty before an in-flight scan finishes",
        .timeLimit(.minutes(1))
    )
    func lastRootRemovalPublishesImmediatelyAndRejectsOlderResults() async throws {
        let workspaceID = UUID()
        let identity = AgentPIDProcessIdentity(
            pid: 100,
            startSeconds: 10,
            startMicroseconds: 0
        )
        let root = AgentPortRootIdentity(pid: 100, processIdentity: identity)
        let runner = SuspendedPortScanCommandRunner()
        let scanner = PortScanner(
            commandRunner: runner,
            processIdentityProvider: { pid in pid == identity.pid ? identity : nil }
        )
        let (publications, publicationContinuation) = AsyncStream<[Int]>.makeStream(
            bufferingPolicy: .unbounded
        )
        var publicationIterator = publications.makeAsyncIterator()
        var removalRevision: UInt64 = 0
        var removalLifecycleWasActiveAtCallback = false
        scanner.onAgentPortsUpdated = { callbackWorkspaceID, ports in
            guard callbackWorkspaceID == workspaceID else { return false }
            if ports.isEmpty {
                removalLifecycleWasActiveAtCallback = scanner.publicationState.isCurrentAgentRevision(
                    removalRevision,
                    workspaceId: workspaceID
                )
            }
            publicationContinuation.yield(ports)
            return true
        }
        defer {
            publicationContinuation.finish()
            scanner.onAgentPortsUpdated = nil
        }

        scanner.refreshAgentPorts(workspaceId: workspaceID, agentRoots: [root])
        await runner.waitUntilProcessScanStarted()
        let initialRevision = scanner.queue.sync {
            scanner.agentRevisionByWorkspace[workspaceID, default: 0]
        }
        scanner.refreshAgentPorts(workspaceId: workspaceID, agentRoots: [root])
        scanner.queue.sync {}
        #expect(scanner.queue.sync {
            scanner.agentRevisionByWorkspace[workspaceID, default: 0]
        } == initialRevision)

        scanner.refreshAgentPorts(workspaceId: workspaceID, agentRoots: [])
        removalRevision = scanner.queue.sync {
            scanner.agentRevisionByWorkspace[workspaceID, default: 0]
        }
        let removedPorts = try #require(await publicationIterator.next())

        let processScanWasReleased = await runner.processScanWasReleased
        #expect(removedPorts == [])
        #expect(processScanWasReleased == false)
        #expect(removalLifecycleWasActiveAtCallback)

        await withCheckedContinuation { continuation in
            scanner.queue.async { continuation.resume() }
        }
        #expect(scanner.publicationState.isCurrentAgentRevision(
            removalRevision,
            workspaceId: workspaceID
        ) == false)

        scanner.refreshAgentPorts(workspaceId: workspaceID, agentRoots: [root])
        scanner.queue.sync {}
        await runner.releaseProcessScan()
        let currentPorts = try #require(await publicationIterator.next())

        #expect([removedPorts, currentPorts] == [[], [5173]])

        await withCheckedContinuation { continuation in
            scanner.queue.async { continuation.resume() }
        }
        scanner.unregisterAgentWorkspace(workspaceId: workspaceID)
        scanner.queue.sync {}
    }
}

private actor SuspendedPortScanCommandRunner: CommandRunning {
    private var processScanStarted = false
    private var processScanReleased = false
    private var lsofRunCount = 0
    private var processStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var processReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    var processScanWasReleased: Bool { processScanReleased }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        _ = (directory, arguments, timeout)
        if executable == "/bin/ps" {
            processScanStarted = true
            processStartWaiters.forEach { $0.resume() }
            processStartWaiters.removeAll()
            if !processScanReleased {
                await withCheckedContinuation { continuation in
                    processReleaseWaiters.append(continuation)
                }
            }
            return Self.result(stdout: "100 1\n")
        }
        if executable == "/usr/sbin/lsof" {
            lsofRunCount += 1
            let port = lsofRunCount == 1 ? 4200 : 5173
            return Self.result(stdout: "p100\nf3\nn*:\(port)\n")
        }
        return Self.result(stdout: "")
    }

    func waitUntilProcessScanStarted() async {
        guard !processScanStarted else { return }
        await withCheckedContinuation { continuation in
            processStartWaiters.append(continuation)
        }
    }

    func releaseProcessScan() {
        processScanReleased = true
        processReleaseWaiters.forEach { $0.resume() }
        processReleaseWaiters.removeAll()
    }

    private static func result(stdout: String) -> CommandResult {
        CommandResult(
            stdout: stdout,
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }
}
