public import CmuxiOSSSHCore
public import CmuxMobileSSH
public import Foundation

/// A shell channel that reports once when its events end (the attached
/// client exited or the connection closed).
public struct SSHEndingShellChannel: SSHShellChannel {
    private let base: any SSHShellChannel
    public let events: AsyncStream<SSHSessionEvent>

    public init(base: any SSHShellChannel, onEnd: @escaping @Sendable () async -> Void) {
        self.base = base
        let upstream = base.events
        events = AsyncStream { continuation in
            let task = Task {
                for await event in upstream { continuation.yield(event) }
                continuation.finish()
                await onEnd()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func write(_ data: Data) async throws { try await base.write(data) }
    public func resize(cols: Int, rows: Int) async throws { try await base.resize(cols: cols, rows: rows) }
    public func close() async { await base.close() }
}
