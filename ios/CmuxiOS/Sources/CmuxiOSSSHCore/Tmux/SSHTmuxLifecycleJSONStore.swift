import Foundation

/// File-backed idempotency ledger for an SSH tmux owner.
///
/// The ledger is intentionally small and append-free: one JSON object maps an
/// idempotency key to its pending/applied record.  Writes use an atomic replace
/// and complete file protection, so an interrupted write leaves the previous
/// decision intact.  A pending record is never discarded automatically; it is
/// the barrier that prevents replaying a command whose SSH response was lost.
public actor SSHTmuxLifecycleJSONStore: SSHTmuxLifecycleRecordStore {
    private let url: URL
    private var records: [String: SSHTmuxLifecycleRecord]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: SSHTmuxLifecycleRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    public func record(for idempotencyKey: String) async throws -> SSHTmuxLifecycleRecord? {
        records[idempotencyKey]
    }

    public func reserve(_ record: SSHTmuxLifecycleRecord) async throws -> SSHTmuxLifecycleRecord? {
        if let existing = records[record.idempotencyKey] { return existing }
        records[record.idempotencyKey] = record
        try persist()
        return nil
    }

    public func replace(_ replacement: SSHTmuxLifecycleRecord,
                        ifCurrent expected: SSHTmuxLifecycleRecord) async throws -> Bool {
        guard records[expected.idempotencyKey] == expected else { return false }
        records[replacement.idempotencyKey] = replacement
        try persist()
        return true
    }

    public func put(_ record: SSHTmuxLifecycleRecord) async throws {
        records[record.idempotencyKey] = record
        try persist()
    }

    private func persist() throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
