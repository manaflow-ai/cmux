import CmuxMobileWire
import Foundation

/// The durable state of one tmux lifecycle idempotency key.
///
/// The record stores the canonical operation instead of the enum directly so
/// a host owner can persist it in its own JSON/SQLite ledger without coupling
/// storage to this module's Swift type layout. A pending record is an explicit
/// barrier: the owner may have run the remote command but not committed its
/// receipt, so retrying it must fail closed rather than run the command twice.
public struct SSHTmuxLifecycleRecord: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case pending
        case applied
    }

    public let idempotencyKey: String
    public let op: String
    public let params: JSONValue
    public let phase: Phase
    public let value: JSONValue?
    public let revision: String?

    private init(idempotencyKey: String, mutation: SSHTmuxLifecycleMutation,
                 phase: Phase, value: JSONValue?, revision: String?) {
        self.idempotencyKey = idempotencyKey
        self.op = mutation.op
        self.params = mutation.params
        self.phase = phase
        self.value = value
        self.revision = revision
    }

    /// Builds the pre-execution barrier record. The operation and key are
    /// validated before this initializer is reached by the owner adapter.
    public init?(pending idempotencyKey: String, mutation: SSHTmuxLifecycleMutation) {
        guard SSHTmuxLifecycleMutation.validIdempotencyKey(idempotencyKey), mutation.isValid else { return nil }
        self.init(idempotencyKey: idempotencyKey, mutation: mutation, phase: .pending, value: nil, revision: nil)
    }

    /// Builds the committed receipt record. A non-empty revision is required
    /// because it is the owner's ordering proof for the resulting state.
    public init?(applied idempotencyKey: String, mutation: SSHTmuxLifecycleMutation,
                 value: JSONValue, revision: String) {
        guard SSHTmuxLifecycleMutation.validIdempotencyKey(idempotencyKey), mutation.isValid,
              Self.validRevision(revision) else { return nil }
        self.init(idempotencyKey: idempotencyKey, mutation: mutation, phase: .applied,
                  value: value, revision: revision)
    }

    /// Reconstructs the validated operation from persisted wire fields.
    public var mutation: SSHTmuxLifecycleMutation? {
        SSHTmuxLifecycleMutation(op: op, params: params)
    }

    public var isComplete: Bool {
        phase == .applied && value != nil && revision.map(Self.validRevision) == true
    }

    private static func validRevision(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...256).contains(bytes.count) else { return false }
        return bytes.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
    }
}
