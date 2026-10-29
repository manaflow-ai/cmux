import CmuxCloud
import CmuxCloudTui
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Holds an already-issued command until explicitly released, even after cancellation.
@MainActor
final class CloudTerminalMutationTestTransport: CloudTuiCommandRunning {
    let started = CloudLinkFirstValue<Bool>()
    let cancelled: CloudLinkFirstValue<Bool>
    private(set) var commands: [String] = []
    private var response: Data?
    private var waiters: [CheckedContinuation<Data, Never>] = []

    init(cancelled: CloudLinkFirstValue<Bool> = CloudLinkFirstValue<Bool>()) {
        self.cancelled = cancelled
    }

    func runTuiCommand(arguments: CloudTuiRequest, deadline: Duration) async throws -> Data {
        commands.append(arguments.operation)
        if let response { return response }
        let cancelled = self.cancelled
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                started.resolve(true)
            }
        } onCancel: {
            cancelled.resolve(true)
        }
    }

    func release(_ response: Data = Data()) {
        self.response = response
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: response) }
    }
}
