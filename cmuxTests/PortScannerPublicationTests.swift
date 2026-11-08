@testable import CmuxComputerUse
import CmuxCore
import CmuxFoundation
import Foundation
import os
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
        // The TTY names below are fixtures, not devices this test owns. The
        // default identity provider opens `/dev/<name>` on the main actor, and
        // on a shared CI host `ttys001`...`ttys003` belong to other sessions:
        // a wedged one blocked that open(2) in the kernel forever. Name
        // changes alone drive the lifecycle revision this test covers.
        let scanner = PortScanner(ttySessionIdentityProvider: { _ in nil })
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
        let childIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 11,
            startMicroseconds: 0
        )
        let root = AgentPortRootIdentity(pid: 100, processIdentity: identity)
        let processTable = SuspendedPortProcessTable()
        // The agent root's own listeners are not badged, so the listener is
        // the root's child. The first scan reports 4200, every later one 5173.
        let portLookupCount = OSAllocatedUnfairLock(initialState: 0)
        let scanner = PortScanner(
            processTable: processTable,
            processIdentityProvider: { pid in
                switch pid {
                case identity.pid: identity
                case childIdentity.pid: childIdentity
                default: nil
                }
            },
            listeningPortsProvider: { pid in
                guard pid == childIdentity.pid else { return .ports([]) }
                let count = portLookupCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                return .ports([count == 1 ? 4200 : 5173])
            }
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
        await processTable.waitUntilProcessScanStarted()
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

        let processScanWasReleased = await processTable.processScanWasReleased
        #expect(removedPorts == [])
        #expect(processScanWasReleased == false)
        #expect(removalLifecycleWasActiveAtCallback)

        // Queue acknowledgement is followed by a main-actor lifecycle update.
        // A queue barrier alone can resume this test before that update runs.
        _ = await AppKitTestEventPump().waitUntil {
            !scanner.publicationState.isCurrentAgentRevision(
                removalRevision,
                workspaceId: workspaceID
            )
        }
        #expect(scanner.publicationState.isCurrentAgentRevision(
            removalRevision,
            workspaceId: workspaceID
        ) == false)

        scanner.refreshAgentPorts(workspaceId: workspaceID, agentRoots: [root])
        scanner.queue.sync {}
        await processTable.releaseProcessScan()
        let currentPorts = try #require(await publicationIterator.next())

        #expect([removedPorts, currentPorts] == [[], [5173]])

        await withCheckedContinuation { continuation in
            scanner.queue.async { continuation.resume() }
        }
        scanner.unregisterAgentWorkspace(workspaceId: workspaceID)
        scanner.queue.sync {}
    }
}

@MainActor
@Suite("Agent port retirement")
struct PortScannerAgentPortRetirementTests {
    @Test(
        "An exited agent listener retires despite an unrelated incomplete PID",
        .timeLimit(.minutes(1))
    )
    func exitedListenerRetiresWithUnrelatedIncompleteProcess() async throws {
        let workspaceID = UUID()
        let rootIdentity = AgentPIDProcessIdentity(
            pid: 100,
            startSeconds: 10,
            startMicroseconds: 0
        )
        let listenerIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 11,
            startMicroseconds: 0
        )
        let unrelatedIdentity = AgentPIDProcessIdentity(
            pid: 102,
            startSeconds: 12,
            startMicroseconds: 0
        )
        let root = AgentPortRootIdentity(pid: 100, processIdentity: rootIdentity)
        // Test seam only: synchronous liveness and port-lookup callbacks must
        // observe one small mutable fixture state atomically.
        let state = OSAllocatedUnfairLock(initialState: AgentPortChurnState(
            rootIdentity: rootIdentity,
            listenerIdentity: listenerIdentity,
            unrelatedIdentity: unrelatedIdentity
        ))
        let scanner = PortScanner(
            processTable: AgentPortChurnProcessTable(),
            processIdentityProvider: { pid in
                state.withLock { $0.identity(for: Int(pid)) }
            },
            processPresenceProvider: { pid in
                state.withLock { $0.presence(for: Int(pid)) }
            },
            listeningPortsProvider: { pid in
                state.withLock { $0.lookUpListeningPorts(pid: Int(pid), port: 4321) }
            }
        )
        let (publications, continuation) = AsyncStream<[Int]>.makeStream(
            bufferingPolicy: .unbounded
        )
        var iterator = publications.makeAsyncIterator()
        scanner.onAgentPortsUpdated = { callbackWorkspaceID, ports in
            guard callbackWorkspaceID == workspaceID else { return false }
            continuation.yield(ports)
            return true
        }
        defer {
            continuation.finish()
            scanner.onAgentPortsUpdated = nil
        }

        scanner.setTrackedAgentScanningPaused(true)
        scanner.refreshAgentPorts(workspaceId: workspaceID, agentRoots: [root])
        let initialPorts = try #require(await iterator.next())
        #expect(initialPorts == [4321])
        let initialRequestedPIDs = state.withLock { Set($0.lookedUpPIDs) }
        #expect(initialRequestedPIDs == [100, 101, 102])
        scanner.queue.sync {}
        let lookupsBeforeExit = state.withLock { state in
            state.stopListening()
            return state.lookedUpPIDs.count
        }

        // The root is looked up once per scan, so its count marks each scan.
        let firstRootLookup = state.withLock { $0.rootLookupCount }
        for expectedLookup in (firstRootLookup + 1)...(firstRootLookup + 3) {
            scanner.refreshAgentPorts(workspaceId: workspaceID, agentRoots: [root])
            try await Self.waitForRootLookup(expectedLookup, in: state)
            scanner.queue.sync {}
        }
        // An unchanged port set is published only while the refresh's force
        // flag survives, and the previous delivery's acknowledgement hops off
        // the main actor before it reaches the scanner queue, so it can clear
        // that flag under a later refresh. Retirement itself is a change and
        // always publishes: drain until it lands instead of expecting one
        // publication per refresh.
        var retiredPorts = initialPorts
        while !retiredPorts.isEmpty {
            retiredPorts = try #require(await iterator.next())
        }
        let postExitRequestedPIDs = state.withLock { $0.lookedUpPIDs.dropFirst(lookupsBeforeExit) }
        #expect(postExitRequestedPIDs.allSatisfy { $0 == 100 })

        scanner.unregisterAgentWorkspace(workspaceId: workspaceID)
        scanner.queue.sync {}
    }

    private static func waitForRootLookup(
        _ target: Int,
        in state: OSAllocatedUnfairLock<AgentPortChurnState>
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while state.withLock({ $0.rootLookupCount }) < target, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(
            state.withLock { $0.rootLookupCount } >= target,
            "port lookup \(target) did not arrive"
        )
    }
}

private struct AgentPortChurnState: Sendable {
    let rootIdentity: AgentPIDProcessIdentity
    let listenerIdentity: AgentPIDProcessIdentity
    let unrelatedIdentity: AgentPIDProcessIdentity
    var listenerIsRunning = true
    var unrelatedPIDIsReadable = true
    /// Every PID the scanner asked the kernel about, in order.
    var lookedUpPIDs: [Int] = []
    var rootLookupCount = 0

    mutating func stopListening() {
        listenerIsRunning = false
        unrelatedPIDIsReadable = false
    }

    /// Stands in for the kernel lookup: only the listener holds the port.
    mutating func lookUpListeningPorts(pid: Int, port: Int) -> ListeningPortLookupResult {
        lookedUpPIDs.append(pid)
        if pid == Int(rootIdentity.pid) {
            rootLookupCount += 1
        }
        guard listenerIsRunning, pid == Int(listenerIdentity.pid) else { return .ports([]) }
        return .ports([port])
    }

    func identity(for pid: Int) -> AgentPIDProcessIdentity? {
        switch pid {
        case Int(rootIdentity.pid):
            rootIdentity
        case Int(listenerIdentity.pid):
            listenerIsRunning ? listenerIdentity : nil
        case Int(unrelatedIdentity.pid):
            unrelatedPIDIsReadable ? unrelatedIdentity : nil
        default:
            // Unknown PIDs are not attributed to the workspace in this fixture.
            nil
        }
    }

    func presence(for pid: Int) -> PIDPresence {
        switch pid {
        case Int(rootIdentity.pid):
            .present
        case Int(listenerIdentity.pid):
            listenerIsRunning ? .present : .absent
        case 102:
            .present
        default:
            .absent
        }
    }
}

/// Stubs the process-table half of each scan; ports come from
/// `AgentPortChurnState.lookUpListeningPorts`.
private struct AgentPortChurnProcessTable: PortProcessTableReading {
    func processesOnTerminals(
        named ttyNames: [String]
    ) async -> (values: [Int: String], completeness: PortScanCompleteness) {
        ([:], .complete)
    }

    func parentsByPID() async -> (values: [Int: Int], completeness: PortScanCompleteness) {
        ([100: 1, 101: 100, 102: 100], .complete)
    }
}

/// Holds every process-table read open until `releaseProcessScan()`, so a test
/// can change agent lifecycles while a scan is in flight.
private actor SuspendedPortProcessTable: PortProcessTableReading {
    private var processScanStarted = false
    private var processScanReleased = false
    private var processStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var processReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    var processScanWasReleased: Bool { processScanReleased }

    func processesOnTerminals(
        named ttyNames: [String]
    ) async -> (values: [Int: String], completeness: PortScanCompleteness) {
        await suspendUntilReleased()
        return ([:], .complete)
    }

    func parentsByPID() async -> (values: [Int: Int], completeness: PortScanCompleteness) {
        await suspendUntilReleased()
        return ([100: 1, 101: 100], .complete)
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

    private func suspendUntilReleased() async {
        processScanStarted = true
        processStartWaiters.forEach { $0.resume() }
        processStartWaiters.removeAll()
        if !processScanReleased {
            await withCheckedContinuation { continuation in
                processReleaseWaiters.append(continuation)
            }
        }
    }
}
