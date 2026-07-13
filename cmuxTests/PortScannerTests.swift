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
