import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct TerminalSSHSessionDetectorProcessExitTests {
    /// Each paste step runs while the rest of the app can hold every global pool
    /// thread (#21551). A step that has exited must be reported as exited, not as
    /// "File transfer timed out" because the wait for its exit needed a free
    /// pool thread.
    @Test("A paste step that exits is seen while the global thread pool is busy")
    func exitedStepIsSeenWhileTheGlobalPoolIsBusy() throws {
        let session = DetectedSSHSession(
            destination: "localhost",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )
        let pool = BusyGlobalPool(workItems: 512)
        defer { pool.release() }
        try #require(pool.isBusy(), "a work item queued on the global queue must wait for this test to say anything")

        let result = try session.runProcessForTesting(executable: "/usr/bin/true", arguments: [], timeout: 2)
        #expect(result.status == 0)
    }
}

/// Holds every thread of the global queue's pool with work items that wait on a
/// gate, so a work item queued after them stays queued until `release()`.
private final class BusyGlobalPool {
    private let gate = DispatchSemaphore(value: 0)
    private let workItems = DispatchGroup()
    private let released = DispatchSemaphore(value: 0)

    init(workItems count: Int) {
        for _ in 0..<count {
            workItems.enter()
            DispatchQueue.global(qos: .userInitiated).async { [gate, workItems] in
                gate.wait()
                workItems.leave()
            }
        }
        // A thread outside the pool opens the gate after a few seconds even if the
        // test is still waiting, so a wait that needs a pool thread cannot hang the run.
        Thread { [gate, released] in
            _ = released.wait(timeout: .now() + 5)
            for _ in 0..<count {
                gate.signal()
            }
        }.start()
    }

    /// True when a work item queued now does not start within a short wait.
    func isBusy() -> Bool {
        let started = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            started.signal()
        }
        return started.wait(timeout: .now() + 0.2) == .timedOut
    }

    /// Opens the gate and waits until every held work item has finished.
    func release() {
        released.signal()
        workItems.wait()
    }
}
