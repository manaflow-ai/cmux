import Testing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux port-badge noise:
/// Claude Code's sandbox network proxies listen from the agent binary's own
/// PID, so ports owned by agent *root* processes must not badge the card,
/// while dev servers launched as agent children must keep theirs.
@Suite struct PortScannerScanJoinTests {
    private let workspaceId = UUID()
    private let agentRootPID = 100
    private let devServerPID = 200
    private let tty = "ttys004"

    private func join(agentRootPIDs: Set<Int>) -> PortScanner.ScanJoinResult {
        PortScanner.joinScanResults(
            pidToPorts: [
                agentRootPID: [55936, 55937],
                devServerPID: [5173],
            ],
            pidToTTY: [
                agentRootPID: tty,
                devServerPID: tty,
            ],
            agentPidToWorkspaces: [
                agentRootPID: [workspaceId],
                devServerPID: [workspaceId],
            ],
            agentRootPIDs: agentRootPIDs
        )
    }

    @Test func agentRootProxyPortsAreExcludedFromPanelPorts() {
        let result = join(agentRootPIDs: [agentRootPID])
        #expect(result.portsByTTY[tty] == [5173])
    }

    @Test func agentRootProxyPortsAreExcludedFromWorkspaceAgentPorts() {
        let result = join(agentRootPIDs: [agentRootPID])
        #expect(result.agentPortsByWorkspace[workspaceId] == [5173])
    }

    @Test func nonAgentScansKeepAllPorts() {
        let result = join(agentRootPIDs: [])
        #expect(result.portsByTTY[tty] == [5173, 55936, 55937])
        #expect(result.agentPortsByWorkspace[workspaceId] == [5173, 55936, 55937])
    }

    @Test func agentRootPIDsUnionsAcrossWorkspaces() {
        let other = UUID()
        let roots = PortScanner.agentRootPIDs(in: [workspaceId: [100, 101], other: [200]])
        #expect(roots == [100, 101, 200])
    }
}

final class PortScannerProcessCaptureTests: XCTestCase {
    private func openFDCount() -> Int? {
        try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    func testCaptureStandardOutputDoesNotLeakPipeFDs() throws {
        guard let baseline = openFDCount() else {
            throw XCTSkip("Unable to inspect /dev/fd on this runner")
        }

        var maxCount = baseline
        for _ in 0..<200 {
            let output = PortScanner.captureStandardOutput(
                executablePath: "/usr/bin/printf",
                arguments: ["cmux"]
            )
            XCTAssertEqual(output, "cmux")
            if let current = openFDCount() {
                maxCount = max(maxCount, current)
            }
        }

        guard let finalCount = openFDCount() else {
            throw XCTSkip("Unable to inspect final /dev/fd count on this runner")
        }

        XCTAssertLessThanOrEqual(maxCount - baseline, 8)
        XCTAssertLessThanOrEqual(finalCount - baseline, 8)
    }
}

final class ProcessTerminationGateTests: XCTestCase {
    func testPrelaunchTerminationRequestIsDeferredUntilLaunch() {
        let gate = ProcessTerminationGate()

        XCTAssertFalse(
            gate.requestTermination(),
            "A cancellation that arrives before Process.run() succeeds must not touch the Process."
        )
        XCTAssertTrue(
            gate.markLaunched(),
            "Once launch succeeds, the deferred termination request should be applied to the running Process."
        )
        gate.markFinished()
        XCTAssertFalse(
            gate.requestTermination(),
            "Late cancellation after completion must not touch Process termination state."
        )
    }

    func testFinishedPrelaunchProcessIgnoresDeferredTermination() {
        let gate = ProcessTerminationGate()

        XCTAssertFalse(gate.requestTermination())
        gate.markFinished()
        XCTAssertFalse(
            gate.markLaunched(),
            "If launch fails and the run is already finished, no deferred termination should be applied."
        )
    }
}
