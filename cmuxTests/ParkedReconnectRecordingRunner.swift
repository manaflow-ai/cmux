import CmuxRemoteSession
import Foundation

/// A host whose SSH transport answers but whose daemon bootstrap never
/// succeeds, recording the bootstrap and relay-cleanup commands it receives.
///
/// Synchronous process-runner callbacks need a lock for the recorder's short
/// state updates; the semaphores hand observations to awaiting tests.
final class ParkedReconnectRecordingRunner: RemoteSessionProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let cleanupObserved = DispatchSemaphore(value: 0)
    private let bootstrapObserved = DispatchSemaphore(value: 0)
    private let cleanupStatus: Int32
    private var cleanupCommands: [String] = []
    private var bootstrapCommands: [String] = []

    /// - Parameter cleanupStatus: Exit status of every relay-metadata cleanup
    ///   script. `64` is the script's "no metadata owned by this relay" answer.
    init(cleanupStatus: Int32) {
        self.cleanupStatus = cleanupStatus
    }

    var bootstrapRequestCount: Int { lock.withLock { bootstrapCommands.count } }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        let command = request.arguments.last ?? ""
        let isCleanup = command.contains("relay_socket=") ||
            command.contains("serve --persistent-stop --slot")
        guard isCleanup else {
            lock.withLock { bootstrapCommands.append(command) }
            bootstrapObserved.signal()
            return RemoteCommandResult(status: 1, stdout: "", stderr: "intentional bootstrap stop")
        }
        lock.withLock { cleanupCommands.append(command) }
        cleanupObserved.signal()
        return RemoteCommandResult(status: cleanupStatus, stdout: "", stderr: "")
    }

    func waitForCleanupCommand() -> String? {
        guard cleanupObserved.wait(timeout: .now() + 10) == .success else { return nil }
        return lock.withLock { cleanupCommands.isEmpty ? nil : cleanupCommands.removeFirst() }
    }

    func waitForBootstrapRequest() -> String? {
        guard bootstrapObserved.wait(timeout: .now() + 10) == .success else { return nil }
        return lock.withLock { bootstrapCommands.last }
    }
}
