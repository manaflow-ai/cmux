import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Port scanner process capture")
struct PortScannerProcessCaptureTests {
    @Test("Malformed ps rows preserve valid mappings but make the scan incomplete")
    func malformedPSRowsAreIncomplete() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "123 ttys001\nmalformed\n456 ttys002 extra\n",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scan = await PortScanner(commandRunner: runner).runPS(ttyList: "ttys001,ttys002")

        #expect(scan.values == [123: "ttys001"])
        #expect(scan.completeness == .incomplete)
    }

    @Test("Malformed lsof rows preserve valid ports but make the scan incomplete")
    func malformedLsofRowsAreIncomplete() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "p123\nf3\nn*:4200\nnmalformed\n",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scan = await PortScanner(commandRunner: runner).runLsof(pidsCsv: "123")

        #expect(scan.values == [123: [4200]])
        #expect(scan.completeness == .incomplete)
    }

    @Test("A clean lsof field stream is complete")
    func cleanLsofRowsAreComplete() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "p123\nf3\nn*:4200\n",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scan = await PortScanner(commandRunner: runner).runLsof(pidsCsv: "123")

        #expect(scan.values == [123: [4200]])
        #expect(scan.completeness == .complete)
    }

    @Test("lsof diagnostics preserve valid ports but make the scan incomplete")
    func lsofDiagnosticsAreIncomplete() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "p123\nf3\nn*:4200\n",
            stderr: "lsof: permission denied\n",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scan = await PortScanner(commandRunner: runner).runLsof(pidsCsv: "123")

        #expect(scan.values == [123: [4200]])
        #expect(scan.completeness == .incomplete)
    }

    @Test("Process scan timeout is bounded and incomplete")
    func processScanTimeoutIsIncomplete() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: nil,
            stderr: nil,
            exitStatus: nil,
            timedOut: true,
            executionError: nil
        ))
        let scan = await PortScanner(commandRunner: runner).runPS(ttyList: "ttys001")
        let timeout = await runner.lastTimeout

        #expect(scan.values.isEmpty)
        #expect(scan.completeness == .incomplete)
        #expect(timeout == PortScanner.processScanTimeout)
    }
}

@Suite("Port scan coordination")
struct PortScanCoordinationTests {
    @Test("Panel scans stay single-flight and coalesce one pending pass")
    func panelScansAreBoundedAndCoalesced() {
        var coordination = PortScanCoordination()

        let firstScan = coordination.beginPanelScan()
        #expect(firstScan)
        let firstPendingScan = coordination.beginPanelScan()
        #expect(firstPendingScan == false)
        let coalescedPendingScan = coordination.beginPanelScan()
        #expect(coalescedPendingScan == false)
        let shouldRunPendingScan = coordination.finishPanelScan()
        #expect(shouldRunPendingScan)
        let pendingScan = coordination.beginPanelScan()
        #expect(pendingScan)
        let isFinished = coordination.finishPanelScan()
        #expect(isFinished == false)
    }

    @Test("Agent scans merge pending workspace inputs behind one in-flight pass")
    func agentScansAreBoundedAndMerged() throws {
        var coordination = PortScanCoordination()
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()
        let first = AgentPortScanRequest(
            workspaceIds: [firstWorkspace],
            pidInput: .captured([firstWorkspace: [100]]),
            agentRevisions: [firstWorkspace: 1],
            requestID: coordination.makeRequestID()
        )
        let newer = AgentPortScanRequest(
            workspaceIds: [firstWorkspace, secondWorkspace],
            pidInput: .captured([firstWorkspace: [101], secondWorkspace: [200]]),
            agentRevisions: [firstWorkspace: 2, secondWorkspace: 1],
            requestID: coordination.makeRequestID()
        )
        let latest = AgentPortScanRequest(
            workspaceIds: [secondWorkspace],
            pidInput: .captured([secondWorkspace: [201]]),
            agentRevisions: [secondWorkspace: 2],
            requestID: coordination.makeRequestID()
        )

        let firstScan = coordination.enqueueAgentScan(first)
        #expect(firstScan == first)
        let coalescedScan = coordination.enqueueAgentScan(newer)
        #expect(coalescedScan == nil)
        let mergedScan = coordination.enqueueAgentScan(latest)
        #expect(mergedScan == nil)
        let finishedScan = coordination.finishAgentScan()
        let pending = try #require(finishedScan)
        let pendingPIDs: [UUID: Set<Int>]
        if case .captured(let pids) = pending.pidInput {
            pendingPIDs = pids
        } else {
            pendingPIDs = [:]
            Issue.record("Expected coalesced captured PID input")
        }
        #expect(pending.workspaceIds == [firstWorkspace, secondWorkspace])
        #expect(pendingPIDs[firstWorkspace] == [101])
        #expect(pendingPIDs[secondWorkspace] == [201])
        #expect(pending.agentRevisions == [firstWorkspace: 2, secondWorkspace: 2])
        #expect(pending.requestID == latest.requestID)

        let nextScan = coordination.enqueueAgentScan(first)
        #expect(nextScan == nil)
        let nextPending = coordination.finishAgentScan()
        #expect(nextPending?.requestID == first.requestID)
    }

    @Test("Provider refresh dominates captured PID inputs when requests coalesce")
    func providerRefreshDominatesCapturedPIDs() {
        let captured = AgentPortScanPIDInput.captured([UUID(): [100]])

        #expect(captured.merging(.refreshProvider) == .refreshProvider)
        #expect(AgentPortScanPIDInput.refreshProvider.merging(captured) == .refreshProvider)
    }

    @Test("Older asynchronous results are rejected after a newer result applies")
    func staleResultsAreRejected() {
        var coordination = PortScanCoordination()
        let workspaceID = UUID()
        let older = coordination.makeRequestID()
        let newer = coordination.makeRequestID()

        let newerPanelResult = coordination.shouldApplyPanelResult(requestID: newer)
        #expect(newerPanelResult)
        let olderPanelResult = coordination.shouldApplyPanelResult(requestID: older)
        #expect(olderPanelResult == false)
        let newerAgentWorkspaces = coordination.newAgentWorkspaces(
            [workspaceID],
            eligibleWorkspaceIds: [workspaceID],
            requestID: newer
        )
        #expect(newerAgentWorkspaces == [workspaceID])
        let olderAgentWorkspaces = coordination.newAgentWorkspaces(
            [workspaceID],
            eligibleWorkspaceIds: [workspaceID],
            requestID: older
        )
        #expect(olderAgentWorkspaces.isEmpty)
        #expect(coordination.isLatestAgentResult(workspaceId: workspaceID, requestID: newer))
    }

    @Test("Agent ordering only retains eligible lifecycle workspaces")
    func agentOrderingOnlyRetainsEligibleWorkspaces() {
        var coordination = PortScanCoordination()
        let panelOnlyWorkspaceID = UUID()
        let forcedClearWorkspaceID = UUID()
        let requestID = coordination.makeRequestID()

        let agentWorkspaces = coordination.newAgentWorkspaces(
            [panelOnlyWorkspaceID, forcedClearWorkspaceID],
            eligibleWorkspaceIds: [forcedClearWorkspaceID],
            requestID: requestID
        )

        #expect(agentWorkspaces == [forcedClearWorkspaceID])
        #expect(coordination.isLatestAgentResult(workspaceId: panelOnlyWorkspaceID, requestID: requestID) == false)
        #expect(coordination.isLatestAgentResult(workspaceId: forcedClearWorkspaceID, requestID: requestID))

        coordination.removeAgentWorkspaces([forcedClearWorkspaceID])

        #expect(coordination.isLatestAgentResult(workspaceId: forcedClearWorkspaceID, requestID: requestID) == false)
    }

    @Test("PID refresh resolution filters stale workspaces before lifecycle removal")
    func stalePIDRefreshCannotRemoveRestartedWorkspace() {
        let staleWorkspace = UUID()
        let inactiveWorkspace = UUID()
        let request = AgentPortScanRequest(
            workspaceIds: [staleWorkspace, inactiveWorkspace],
            pidInput: .refreshProvider,
            agentRevisions: [staleWorkspace: 1, inactiveWorkspace: 1],
            requestID: 1
        )

        let resolution = request.resolvingPIDs(
            [:],
            currentRevisions: [staleWorkspace: 2, inactiveWorkspace: 1]
        )

        #expect(resolution.request.workspaceIds == [inactiveWorkspace])
        #expect(resolution.inactiveWorkspaceIds == [inactiveWorkspace])
        #expect(resolution.inactiveWorkspaceIds.contains(staleWorkspace) == false)
    }
}

@MainActor
@Suite("Port scan publication lifecycle")
struct PortScanPublicationStateTests {
    @Test("A newer lifecycle revision rejects a queued stale publication")
    func staleRevisionIsRejected() {
        let state = PortScanPublicationState()
        let workspaceID = UUID()
        let staleRevision = state.nextAgentRevision(for: workspaceID)
        let currentRevision = state.nextAgentRevision(for: workspaceID)

        #expect(state.isCurrentAgentRevision(staleRevision, workspaceId: workspaceID) == false)
        #expect(state.isCurrentAgentRevision(currentRevision, workspaceId: workspaceID))
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
}

@Suite("Agent port tracking lifecycle")
struct AgentPortTrackingStateTests {
    @Test("Only a changed root PID set starts a new snapshot lifecycle")
    func rootPIDChangesDelimitSnapshots() {
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
        let recycled = state.replaceRoots([recycledPID], workspaceId: workspaceID)
        let stopped = state.replaceRoots([], workspaceId: workspaceID)
        let repeatedStop = state.replaceRoots([], workspaceId: workspaceID)
        let restarted = state.replaceRoots([first], workspaceId: workspaceID)

        #expect(initial)
        #expect(repeated == false)
        #expect(recycled)
        #expect(stopped)
        #expect(repeatedStop == false)
        #expect(restarted)
    }
}

@Suite("Agent port publication history")
struct AgentPortPublicationHistoryTests {
    @Test("Pending desired values keep the newest request publishable")
    func pendingValuesAreNotDeduplicatedAgainstAcknowledgedState() {
        var history = AgentPortPublicationHistory()
        let workspaceID = UUID()

        let initial = history.shouldPublish(workspaceId: workspaceID, ports: [4200], forced: false)
        let samePending = history.shouldPublish(workspaceId: workspaceID, ports: [4200], forced: false)
        history.acknowledge(workspaceId: workspaceID, ports: [4200])
        let sameAcknowledged = history.shouldPublish(
            workspaceId: workspaceID,
            ports: [4200],
            forced: false
        )
        let changed = history.shouldPublish(workspaceId: workspaceID, ports: [5173], forced: false)
        let restored = history.shouldPublish(workspaceId: workspaceID, ports: [4200], forced: false)

        #expect(initial)
        #expect(samePending)
        #expect(sameAcknowledged == false)
        #expect(changed)
        #expect(restored)
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
        #expect(buffer.isDrainScheduled)
        let emptyBatch = buffer.takePendingBatch()
        #expect(emptyBatch?.isEmpty == nil)
        #expect(buffer.isDrainScheduled == false)
    }

    @Test("Agent updates coalesce by lifecycle revision and request ordering")
    func agentUpdatesKeepLatestLifecycleValue() throws {
        var buffer = PortScanPublicationBuffer()
        let workspaceID = UUID()
        let first = AgentPortScanPublication(
            workspaceId: workspaceID,
            ports: [4000],
            revision: 1,
            requestID: 1,
            removesLifecycle: false
        )
        let latestRequest = AgentPortScanPublication(
            workspaceId: workspaceID,
            ports: [4200],
            revision: 1,
            requestID: 2,
            removesLifecycle: false
        )
        let staleLifecycle = AgentPortScanPublication(
            workspaceId: workspaceID,
            ports: [4300],
            revision: 0,
            requestID: 99,
            removesLifecycle: false
        )

        let didScheduleInitialDrain = buffer.enqueue(agentPublications: [first])
        let didScheduleLatestRequestDrain = buffer.enqueue(agentPublications: [latestRequest])
        let didScheduleStaleLifecycleDrain = buffer.enqueue(agentPublications: [staleLifecycle])
        #expect(didScheduleInitialDrain)
        #expect(didScheduleLatestRequestDrain == false)
        #expect(didScheduleStaleLifecycleDrain == false)

        let pendingBatch = buffer.takePendingBatch()
        let batch = try #require(pendingBatch)
        #expect(batch.agentPublicationsByWorkspace[workspaceID]?.ports == [4200])

        let nextLifecycle = AgentPortScanPublication(
            workspaceId: workspaceID,
            ports: [4400],
            revision: 2,
            requestID: 3,
            removesLifecycle: false
        )
        let didScheduleNextLifecycleDrain = buffer.enqueue(agentPublications: [nextLifecycle])
        let nextLifecycleBatch = buffer.takePendingBatch()
        let emptyBatch = buffer.takePendingBatch()
        #expect(didScheduleNextLifecycleDrain == false)
        #expect(nextLifecycleBatch?.agentPublicationsByWorkspace[workspaceID]?.ports == [4400])
        #expect(emptyBatch?.isEmpty == nil)
    }
}

@Suite("Process termination gate")
struct ProcessTerminationGateTests {
    @Test("A prelaunch termination request is deferred until launch")
    func prelaunchTerminationRequestIsDeferredUntilLaunch() {
        let gate = ProcessTerminationGate()

        #expect(gate.requestTermination() == false)
        #expect(gate.markLaunched())
        gate.markFinished()
        #expect(gate.requestTermination() == false)
    }

    @Test("A finished prelaunch process ignores deferred termination")
    func finishedPrelaunchProcessIgnoresDeferredTermination() {
        let gate = ProcessTerminationGate()

        #expect(gate.requestTermination() == false)
        gate.markFinished()
        #expect(gate.markLaunched() == false)
    }
}

private actor StubCommandRunner: CommandRunning {
    let result: CommandResult
    private(set) var lastTimeout: TimeInterval?

    init(result: CommandResult) {
        self.result = result
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        lastTimeout = timeout
        return result
    }
}
