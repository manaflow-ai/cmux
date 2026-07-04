import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the launch/cancel race in `RemoteTmuxProcessCancellation`.
///
/// The remote tmux kill path relies on a hard timeout: when the enclosing task is
/// cancelled, the child SSH process must not be able to start (or keep running) past
/// the deadline. The subtle failure mode is a cancellation that lands after the
/// caller's `Task.checkCancellation()` but before `process.run()` — the old
/// `isRunning`-only guard observed a not-yet-running process, did nothing, and then
/// the child launched unguarded and could hang. These tests pin both orderings.
@Suite struct RemoteTmuxProcessCancellationTests {
    /// cancel() before launch() must prevent the child from ever starting.
    @Test func cancelBeforeLaunchPreventsProcessStart() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        let cancellation = RemoteTmuxProcessCancellation(
            process: process,
            stdout: outPipe.fileHandleForReading,
            stderr: errPipe.fileHandleForReading
        )

        await cancellation.cancel()

        await #expect(throws: CancellationError.self) {
            try await cancellation.launch()
        }
        // The child must never have been spawned.
        #expect(process.isRunning == false)
    }

    /// launch() before cancel() must still terminate the running child promptly.
    @Test func launchThenCancelTerminatesRunningProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        let cancellation = RemoteTmuxProcessCancellation(
            process: process,
            stdout: outPipe.fileHandleForReading,
            stderr: errPipe.fileHandleForReading
        )

        let launchTask = Task {
            try await cancellation.launch()
        }
        let launchDeadline = Date().addingTimeInterval(1)
        while !process.isRunning, Date() < launchDeadline {
            usleep(20_000)
        }
        #expect(process.isRunning == true)

        await cancellation.cancel()

        // SIGTERM from cancel() should stop `sleep` well within this bound; poll so the
        // test never blocks indefinitely if termination were to regress.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        let stoppedByCancel = !process.isRunning
        // Safety net: if SIGTERM were somehow ignored (heavy load, process-group edge
        // cases, or a future cancel() regression), escalate to SIGKILL and reap the
        // child before asserting so this test can never leak an orphaned `sleep`.
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        _ = try await launchTask.value
        #expect(stoppedByCancel)
    }
}
