import Darwin
import Foundation
import Testing

struct WorkspaceSSHFishProcessDrainTests {
    @Test(arguments: [false, true])
    func drainsOutputLargerThanPipeBuffer(stderr: Bool) {
        let redirect = stderr ? "1>&2" : ""
        let result = SSHFishProcessRunner.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "/bin/dd if=/dev/zero bs=65536 count=8 \(redirect) 2>/dev/null; printf done >&2"],
            environment: ProcessInfo.processInfo.environment,
            timeout: 10
        )
        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stderr.hasSuffix("done"))
        if stderr { #expect(result.stderr.utf8.count == 524_292) }
    }

    @Test
    func timeoutKillsChildThatIgnoresTermination() {
        let result = SSHFishProcessRunner.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "trap '' TERM; printf ready >&2; exec /bin/sleep 60"],
            environment: ProcessInfo.processInfo.environment,
            timeout: 5
        )
        #expect(result.timedOut)
        #expect(result.status == SIGKILL)
        #expect(result.stderr == "ready")
    }

    @Test
    func inheritedWriterDoesNotHoldReturnUntilEOF() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fish-drain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pidFile = directory.appendingPathComponent("pid")
        defer {
            if let raw = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_DRAIN_PID_FILE"] = pidFile.path
        let result = SSHFishProcessRunner.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "/bin/sleep 15 & echo $! > \"$CMUX_DRAIN_PID_FILE\"; printf parent-exited >&2"],
            environment: environment,
            timeout: 5
        )
        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stderr == "parent-exited")
        let raw = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Returning while the writer is alive proves we did not wait for EOF.
        #expect(kill(pid, 0) == 0)
    }
}

// Shared with the fish integration test so these regressions exercise its
// real process lifecycle, without requiring fish or an SSH server.
enum SSHFishProcessRunner {
    struct ProcessRunResult { let status: Int32; let stderr: String; let timedOut: Bool }

    /// Collects a pipe's bytes from a drain thread while the child still runs.
    private final class CapturedOutput: @unchecked Sendable {
        private let lock = NSLock(); private var data = Data()

        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    static func runProcess(
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
        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }

        do {
            try process.run()
        } catch {
            return ProcessRunResult(
                status: -1,
                stderr: String(describing: error),
                timedOut: false
            )
        }

        // Close our copies of the write ends: the child holds its own, and a
        // writer left open here would keep the drains below from seeing EOF.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // Drain both pipes while the child is still running. Reading only
        // after exit deadlocks a child that writes more than the pipe buffer:
        // it blocks on write while we block on its exit.
        let capturedStderr = CapturedOutput()
        let drains = DispatchGroup()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async(group: drains) {
            while !stdoutHandle.availableData.isEmpty {}
        }
        DispatchQueue.global(qos: .userInitiated).async(group: drains) {
            while true {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { break }
                capturedStderr.append(chunk)
            }
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exitSignal.wait()
            }
        }

        // A backgrounded grandchild (an SSH control master, for one) inherits
        // these write ends and holds them open past the direct child's exit,
        // so EOF may never arrive. Bound the drain and report what we read
        // rather than hanging the suite on it.
        _ = drains.wait(timeout: .now() + 2)
        let stderr = String(data: capturedStderr.value, encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.terminationStatus,
            stderr: stderr,
            timedOut: timedOut
        )
    }

}
