import Darwin
import XCTest

final class CLIStdioSIGPIPERegressionTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private struct SIGPIPEInspectResult: Decodable {
        let signal: String
        let stdout_nosigpipe: Int32
        let stderr_nosigpipe: Int32
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    private func cliTestEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        return environment
    }

    private func closedPipeWriteHandle(named name: String) throws -> FileHandle {
        var pipeFDs = [Int32](repeating: 0, count: 2)
        guard pipe(&pipeFDs) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create \(name) pipe"]
            )
        }

        let readFD = pipeFDs[0]
        let writeFD = pipeFDs[1]
        guard Darwin.close(readFD) == 0 else {
            let code = Int(errno)
            Darwin.close(writeFD)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to close read end of \(name) pipe"]
            )
        }

        return FileHandle(fileDescriptor: writeFD, closeOnDealloc: false)
    }

    private func waitForExit(
        of process: Process,
        description: String,
        timeout: TimeInterval = 5
    ) -> XCTWaiter.Result {
        let exited = expectation(description: description)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.fulfill()
        }
        return XCTWaiter().wait(for: [exited], timeout: timeout)
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(
                status: -1,
                stdout: "",
                stderr: String(describing: error),
                timedOut: false
            )
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    @MainActor
    func testVersionDoesNotAbortWhenStdoutPipeIsClosed() throws {
        let cliPath = try bundledCLIPath()
        let process = Process()
        let stdoutHandle = try closedPipeWriteHandle(named: "stdout")
        defer { try? stdoutHandle.close() }

        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["version"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = Pipe()
        process.environment = cliTestEnvironment()

        try process.run()

        let waitResult = waitForExit(of: process, description: "cli exited after closed stdout pipe")
        guard waitResult == .completed else {
            process.terminate()
            XCTFail("CLI did not exit within 5s after closed stdout pipe")
            return
        }

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
    }

    @MainActor
    func testReadScreenArgumentErrorPreservesExitCodeWhenStderrPipeIsClosed() throws {
        let cliPath = try bundledCLIPath()
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrHandle = try closedPipeWriteHandle(named: "stderr")
        defer { try? stderrHandle.close() }

        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["read-screen", "--lines", "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrHandle
        process.environment = cliTestEnvironment()

        try process.run()

        let waitResult = waitForExit(of: process, description: "cli exited after closed stderr pipe")
        guard waitResult == .completed else {
            process.terminate()
            XCTFail("CLI did not exit within 5s after closed stderr pipe")
            return
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(
            process.terminationReason,
            .exit,
            "Expected closed stderr pipe to exit normally; stdout=\(stdout)"
        )
        XCTAssertEqual(
            process.terminationStatus,
            1,
            "Expected closed stderr pipe to preserve the command failure exit code; stdout=\(stdout)"
        )
    }

    @MainActor
    func testCLIProcessRunnerInputPipeIgnoresBrokenPipeWhenChildClosesStdin() throws {
        let cliPath = try bundledCLIPath()
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["__sigpipe-stdin-pipe-probe"],
            environment: cliTestEnvironment(),
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "ok\n", result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
    }

    @MainActor
    func testSIGPIPEProbeChildrenSeeDefaultDisposition() throws {
        let cliPath = try bundledCLIPath()
        for mode in ["spawn", "spawn-stderr", "exec"] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["__sigpipe-probe", mode],
                environment: cliTestEnvironment(),
                timeout: 5
            )

            XCTAssertFalse(result.timedOut, "Mode \(mode) timed out: \(result.stderr)")
            XCTAssertEqual(result.status, 0, "Mode \(mode) failed: \(result.stderr)")
            XCTAssertTrue(result.stderr.isEmpty, "Mode \(mode) wrote unexpected stderr: \(result.stderr)")

            let inspection = try JSONDecoder().decode(
                SIGPIPEInspectResult.self,
                from: Data(result.stdout.utf8)
            )
            XCTAssertEqual(inspection.signal, "default", "Mode \(mode) inherited the wrong SIGPIPE disposition")
            XCTAssertEqual(inspection.stdout_nosigpipe, 0, "Mode \(mode) leaked F_NOSIGPIPE onto stdout")
            XCTAssertEqual(inspection.stderr_nosigpipe, 0, "Mode \(mode) leaked F_NOSIGPIPE onto stderr")
        }
    }
}
