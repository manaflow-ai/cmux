import CmuxCore
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

@Suite("Agent process identity validation")
struct AgentProcessIdentityValidationTests {
    @Test("A matching birth identity is retained for process-tree expansion")
    func matchingIdentityIsAccepted() {
        let workspaceID = UUID()
        let identity = AgentPIDProcessIdentity(
            pid: 100,
            startSeconds: 10,
            startMicroseconds: 20
        )
        let root = AgentPortRootIdentity(pid: 100, processIdentity: identity)
        let scanner = PortScanner(processIdentityProvider: { pid in
            pid == identity.pid ? identity : nil
        })

        let validation = scanner.validateAgentRoots([workspaceID: [root]])

        #expect(validation.values == [workspaceID: [root]])
        #expect(validation.completeness == .complete)
    }

    @Test("A recycled root PID cannot retain ownership of the expanded process tree")
    func recycledPIDIsRejectedBeforeLsof() {
        let workspaceID = UUID()
        let recorded = AgentPIDProcessIdentity(pid: 100, startSeconds: 10, startMicroseconds: 20)
        let recycled = AgentPIDProcessIdentity(pid: 100, startSeconds: 11, startMicroseconds: 0)
        let root = AgentPortRootIdentity(pid: 100, processIdentity: recorded)
        let scanner = PortScanner(processIdentityProvider: { _ in recycled })

        let revalidated = scanner.revalidateAgentProcessTree(
            [100: [workspaceID], 101: [workspaceID]],
            rootsByWorkspace: [workspaceID: [root]]
        )

        #expect(revalidated.values.isEmpty)
        #expect(revalidated.completeness == .complete)
    }

    @Test("An unavailable birth-identity probe is incomplete negative evidence")
    func unavailableIdentityProbeIsIncomplete() {
        let workspaceID = UUID()
        let identity = AgentPIDProcessIdentity(pid: 100, startSeconds: 10, startMicroseconds: 20)
        let root = AgentPortRootIdentity(pid: 100, processIdentity: identity)
        let scanner = PortScanner(processIdentityProvider: { _ in nil })

        let validation = scanner.validateAgentRoots([workspaceID: [root]])

        #expect(validation.values.isEmpty)
        #expect(validation.completeness == .incomplete)
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
            rootInput: AgentPortScanRootInput(
                rootsByWorkspace: [firstWorkspace: [AgentPortRootIdentity(pid: 100, processIdentity: nil)]]
            ),
            agentRevisions: [firstWorkspace: 1],
            requestID: coordination.makeRequestID()
        )
        let newer = AgentPortScanRequest(
            workspaceIds: [firstWorkspace, secondWorkspace],
            rootInput: AgentPortScanRootInput(rootsByWorkspace: [
                firstWorkspace: [AgentPortRootIdentity(pid: 101, processIdentity: nil)],
                secondWorkspace: [AgentPortRootIdentity(pid: 200, processIdentity: nil)]
            ]),
            agentRevisions: [firstWorkspace: 2, secondWorkspace: 1],
            requestID: coordination.makeRequestID()
        )
        let latest = AgentPortScanRequest(
            workspaceIds: [secondWorkspace],
            rootInput: AgentPortScanRootInput(
                rootsByWorkspace: [secondWorkspace: [AgentPortRootIdentity(pid: 201, processIdentity: nil)]]
            ),
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
        let pendingRoots = pending.rootInput.rootsByWorkspace
        #expect(pending.workspaceIds == [firstWorkspace, secondWorkspace])
        #expect(pendingRoots[firstWorkspace]?.map(\.pid) == [101])
        #expect(pendingRoots[secondWorkspace]?.map(\.pid) == [201])
        #expect(pending.agentRevisions == [firstWorkspace: 2, secondWorkspace: 2])
        #expect(pending.requestID == latest.requestID)

        let nextScan = coordination.enqueueAgentScan(first)
        #expect(nextScan == nil)
        let nextPending = coordination.finishAgentScan()
        #expect(nextPending?.requestID == first.requestID)
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
