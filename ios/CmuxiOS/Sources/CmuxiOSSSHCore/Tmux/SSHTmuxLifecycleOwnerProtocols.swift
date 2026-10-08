import CmuxMobileWire
import Foundation

/// Storage owned by the SSH host for lifecycle operation records.
///
/// Implementations must make `put` durable before it returns. A pending
/// record therefore survives an owner restart and prevents an uncertain raw
/// SSH command from being replayed automatically.
public protocol SSHTmuxLifecycleRecordStore: Sendable {
    func record(for idempotencyKey: String) async throws -> SSHTmuxLifecycleRecord?
    func put(_ record: SSHTmuxLifecycleRecord) async throws
}

/// The host-side command boundary. The implementation must revalidate the
/// mutation's server epoch immediately before issuing its tmux command; the
/// adapter cannot safely infer that a check made earlier is still current.
public protocol SSHTmuxLifecycleExecutor: Sendable {
    func execute(_ mutation: SSHTmuxLifecycleMutation) async throws -> SSHTmuxLifecycleExecution
}

/// The owner result produced after a command has been applied.
public struct SSHTmuxLifecycleExecution: Hashable, Sendable {
    public let value: JSONValue
    public let revision: String

    public init?(value: JSONValue, revision: String) {
        let bytes = Array(revision.utf8)
        guard (1...256).contains(bytes.count), bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
            return nil
        }
        self.value = value
        self.revision = revision
    }
}
