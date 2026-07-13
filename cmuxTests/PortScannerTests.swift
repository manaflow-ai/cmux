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

        #expect(coordination.beginPanelScan())
        #expect(coordination.beginPanelScan() == false)
        #expect(coordination.beginPanelScan() == false)
        #expect(coordination.finishPanelScan())
        #expect(coordination.beginPanelScan())
        #expect(coordination.finishPanelScan() == false)
    }

    @Test("Agent scans merge pending workspace inputs behind one in-flight pass")
    func agentScansAreBoundedAndMerged() throws {
        var coordination = PortScanCoordination()
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()
        let first = AgentPortScanRequest(
            workspaceIds: [firstWorkspace],
            agentPIDsByWorkspace: [firstWorkspace: [100]],
            agentRevisions: [firstWorkspace: 1],
            requestID: coordination.makeRequestID()
        )
        let newer = AgentPortScanRequest(
            workspaceIds: [firstWorkspace, secondWorkspace],
            agentPIDsByWorkspace: [firstWorkspace: [101], secondWorkspace: [200]],
            agentRevisions: [firstWorkspace: 2, secondWorkspace: 1],
            requestID: coordination.makeRequestID()
        )

        #expect(coordination.enqueueAgentScan(first) == first)
        #expect(coordination.enqueueAgentScan(newer) == nil)
        let pending = try #require(coordination.finishAgentScan())
        #expect(pending.workspaceIds == [firstWorkspace, secondWorkspace])
        #expect(pending.agentPIDsByWorkspace[firstWorkspace] == [101])
        #expect(pending.agentPIDsByWorkspace[secondWorkspace] == [200])
        #expect(pending.requestID == newer.requestID)

        #expect(coordination.enqueueAgentScan(first) == nil)
        #expect(coordination.finishAgentScan()?.requestID == first.requestID)
    }

    @Test("Older asynchronous results are rejected after a newer result applies")
    func staleResultsAreRejected() {
        var coordination = PortScanCoordination()
        let workspaceID = UUID()
        let older = coordination.makeRequestID()
        let newer = coordination.makeRequestID()

        #expect(coordination.shouldApplyPanelResult(requestID: newer))
        #expect(coordination.shouldApplyPanelResult(requestID: older) == false)
        #expect(coordination.newAgentWorkspaces([workspaceID], requestID: newer) == [workspaceID])
        #expect(coordination.newAgentWorkspaces([workspaceID], requestID: older).isEmpty)
        #expect(coordination.isLatestAgentResult(workspaceId: workspaceID, requestID: newer))
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
