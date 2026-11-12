import Foundation

/// Waits for `process` to exit on the calling thread, polling `isRunning`.
///
/// Returns `.success` once the process has exited, `.timedOut` if it is still
/// running at the deadline. Use this instead of queueing a blocking
/// `waitUntilExit()` on `DispatchQueue.global()` and waiting on a semaphore:
/// every queued waiter pins a pool thread until its child exits, waiters for
/// children that never exit accumulate across a test batch, and once the pool
/// is exhausted a new waiter never starts, so a child that exited normally is
/// reported as a timeout.
func waitForProcessExit(_ process: Process, timeout: TimeInterval) -> DispatchTimeoutResult {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning {
        if Date() >= deadline {
            return .timedOut
        }
        usleep(5_000)
    }
    return .success
}
