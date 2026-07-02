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
    @Test func cancelBeforeLaunchPreventsProcessStart() throws {
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

        cancellation.cancel()

        #expect(throws: CancellationError.self) {
            try cancellation.launch()
        }
        // The child must never have been spawned.
        #expect(process.isRunning == false)
    }

    /// launch() before cancel() must still terminate the running child promptly.
    @Test func launchThenCancelTerminatesRunningProcess() throws {
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

        try cancellation.launch()
        #expect(process.isRunning == true)

        cancellation.cancel()

        // SIGTERM from cancel() should stop `sleep` well within this bound; poll so the
        // test never blocks indefinitely if termination were to regress.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        #expect(process.isRunning == false)
    }
}
