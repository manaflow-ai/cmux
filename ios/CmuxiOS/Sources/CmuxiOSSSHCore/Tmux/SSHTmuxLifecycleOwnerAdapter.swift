import Foundation

/// Errors raised before a lifecycle command can be safely submitted.
public enum SSHTmuxLifecycleOwnerError: Error, Equatable, Sendable {
    case invalidRequest
    case noPendingRecord
    case idempotencyConflict
    case indeterminate
    case malformedRecord
}

/// Durable owner adapter for tmux create/rename/kill operations.
///
/// The sequence is intentionally strict:
///
/// 1. Return an applied record as a replay without executing anything.
/// 2. Refuse an existing pending record because its prior command outcome is
///    unknown.
/// 3. Persist a pending fingerprint before invoking the executor.
/// 4. Persist the applied receipt before returning it.
///
/// This actor serializes calls in one process; the durable record store is the
/// cross-process/restart boundary. It does not perform SSH I/O itself and is
/// therefore independent from D1b app wiring.
public actor SSHTmuxLifecycleOwnerAdapter: SSHTmuxLifecycleMutating {
    private let store: any SSHTmuxLifecycleRecordStore
    private let executor: any SSHTmuxLifecycleExecutor

    public init(store: any SSHTmuxLifecycleRecordStore, executor: any SSHTmuxLifecycleExecutor) {
        self.store = store
        self.executor = executor
    }

    private func replay(_ existing: SSHTmuxLifecycleRecord, mutation: SSHTmuxLifecycleMutation,
                        idempotencyKey: String) throws -> SSHTmuxLifecycleReceipt {
        guard existing.idempotencyKey == idempotencyKey,
              existing.op == mutation.op,
              existing.params == mutation.params else {
            throw SSHTmuxLifecycleOwnerError.idempotencyConflict
        }
        switch existing.phase {
        case .pending:
            throw SSHTmuxLifecycleOwnerError.indeterminate
        case .applied:
            guard existing.isComplete, let value = existing.value, let revision = existing.revision,
                  let recordedMutation = existing.mutation else {
                throw SSHTmuxLifecycleOwnerError.malformedRecord
            }
            return SSHTmuxLifecycleReceipt(idempotencyKey: idempotencyKey, mutation: recordedMutation,
                                           value: value, revision: revision, replayed: true)
        }
    }

    public func submit(_ mutation: SSHTmuxLifecycleMutation, idempotencyKey: String) async throws -> SSHTmuxLifecycleReceipt {
        guard SSHTmuxLifecycleMutation.validIdempotencyKey(idempotencyKey), mutation.isValid else {
            throw SSHTmuxLifecycleOwnerError.invalidRequest
        }

        guard let pending = SSHTmuxLifecycleRecord(pending: idempotencyKey, mutation: mutation) else {
            throw SSHTmuxLifecycleOwnerError.invalidRequest
        }
        // This conditional write is the replay barrier. It must be atomic in
        // the durable ledger so two host processes cannot both observe an
        // absent key and issue the same SSH command.
        if let existing = try await store.reserve(pending) {
            return try replay(existing, mutation: mutation, idempotencyKey: idempotencyKey)
        }

        // An executor error intentionally leaves `pending` in the store. The
        // caller receives the original error; a later retry gets `.indeterminate`.
        let execution = try await executor.execute(mutation)
        guard let applied = SSHTmuxLifecycleRecord(applied: idempotencyKey, mutation: mutation,
                                                   value: execution.value, revision: execution.revision) else {
            throw SSHTmuxLifecycleOwnerError.malformedRecord
        }
        try await store.put(applied)
        return SSHTmuxLifecycleReceipt(idempotencyKey: idempotencyKey, mutation: mutation,
                                       value: execution.value, revision: execution.revision, replayed: false)
    }

    /// Resolves a pending operation after the host has read the current tmux
    /// state and proved that the requested mutation already took effect. The
    /// readback is supplied by the owner, so this method never runs a second
    /// command. An applied record is returned as the existing replay and a
    /// missing record is refused rather than creating a receipt without the
    /// original durable reservation.
    public func reconcilePending(_ mutation: SSHTmuxLifecycleMutation, idempotencyKey: String,
                                 readback: SSHTmuxLifecycleExecution) async throws -> SSHTmuxLifecycleReceipt {
        guard SSHTmuxLifecycleMutation.validIdempotencyKey(idempotencyKey), mutation.isValid else {
            throw SSHTmuxLifecycleOwnerError.invalidRequest
        }
        guard let existing = try await store.record(for: idempotencyKey) else {
            throw SSHTmuxLifecycleOwnerError.noPendingRecord
        }
        guard existing.idempotencyKey == idempotencyKey,
              existing.op == mutation.op, existing.params == mutation.params else {
            throw SSHTmuxLifecycleOwnerError.idempotencyConflict
        }
        switch existing.phase {
        case .applied:
            return try replay(existing, mutation: mutation, idempotencyKey: idempotencyKey)
        case .pending:
            guard let applied = SSHTmuxLifecycleRecord(applied: idempotencyKey, mutation: mutation,
                                                       value: readback.value, revision: readback.revision) else {
                throw SSHTmuxLifecycleOwnerError.malformedRecord
            }
            try await store.put(applied)
            return SSHTmuxLifecycleReceipt(idempotencyKey: idempotencyKey, mutation: mutation,
                                           value: readback.value, revision: readback.revision, replayed: true)
        }
    }
}
