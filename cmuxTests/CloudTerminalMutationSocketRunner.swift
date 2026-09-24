import CmuxCloudTui
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Uses the real persistent connection and records cancellation at its RPC boundary.
/// The lock protects only counters reached synchronously by task cancellation callbacks.
final class CloudTerminalMutationSocketRunner: CloudTuiCommandRunning, @unchecked Sendable {
    private let channel: CloudTuiPersistentResourceConnection
    private let lock = NSLock()
    private var cancellations = 0
    private var operations: [String] = []

    init(channel: CloudTuiPersistentResourceConnection) {
        self.channel = channel
    }

    var cancellationCount: Int { lock.withLock { cancellations } }
    var commands: [String] { lock.withLock { operations } }

    func runTuiCommand(arguments: CloudTuiRequest, deadline: Duration) async throws -> Data {
        lock.withLock { operations.append(arguments.operation) }
        return try await withTaskCancellationHandler {
            try await channel.request(arguments, timeout: deadline)
        } onCancel: {
            self.lock.withLock { self.cancellations += 1 }
        }
    }
}
