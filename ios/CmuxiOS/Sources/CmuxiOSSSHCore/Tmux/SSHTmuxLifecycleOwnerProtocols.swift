import CmuxMobileWire
import Foundation

/// Storage owned by the SSH host for lifecycle operation records.
///
/// Implementations must make `put` durable before it returns. A pending
/// record therefore survives an owner restart and prevents an uncertain raw
/// SSH command from being replayed automatically.
public protocol SSHTmuxLifecycleRecordStore: Sendable {
    func record(for idempotencyKey: String) async throws -> SSHTmuxLifecycleRecord?
    /// Atomically installs a pending record when the key is absent.
    ///
    /// The return value is the record already owned by another caller, or
    /// `nil` when this call installed `record`. Implementations must make the
    /// check-and-insert one durable transaction; an actor-local check followed
    /// by `put` is insufficient when two host processes share the ledger.
    func reserve(_ record: SSHTmuxLifecycleRecord) async throws -> SSHTmuxLifecycleRecord?
    /// Atomically replaces `expected` with `replacement` when the key still
    /// points at that exact pending record. Returns false when another owner
    /// has already resolved or removed it; callers must then read the current
    /// record and fail closed if it is not an applied receipt.
    func replace(_ replacement: SSHTmuxLifecycleRecord,
                 ifCurrent expected: SSHTmuxLifecycleRecord) async throws -> Bool
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
