public import CmuxiOSFeatureKit
public import Foundation

/// The on-device owner of SSH and direct host records (`HostsStore`).
///
/// Records persist as JSON in Application Support with complete file
/// protection; every commit bumps the revision, writes the file, yields one
/// snapshot to each subscriber and publishes to the sync seam. Intents are
/// idempotent by key (a replay returns the first receipt). A refused intent
/// changes nothing. Paired Macs are refused: lane B6 owns them.
public actor LocalHostsStore: HostsStore {
    private let url: URL
    private let sync: any HostsSyncChannel
    private var hosts: [HostRecord]
    private var revision: UInt64
    private var receipts: [IntentKey: IntentReceipt] = [:]
    private var receiptOrder: [IntentKey] = []
    private var subscribers: [UUID: AsyncStream<SourceSnapshot<[HostRecord]>>.Continuation] = [:]

    /// Receipts remembered for replay.
    static let receiptMemory = 256

    public init(url: URL, sync: any HostsSyncChannel = DisabledHostsSync()) {
        self.url = url
        self.sync = sync
        let file = (try? JSONDecoder().decode(StoredHostsFile.self, from: Data(contentsOf: url)))
        hosts = file?.hosts.map(\.record) ?? []
        revision = file?.revision ?? 0
    }

    public func updates() async -> AsyncStream<SourceSnapshot<[HostRecord]>> {
        let (stream, continuation) = AsyncStream.makeStream(of: SourceSnapshot<[HostRecord]>.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    /// The current records (for screens that need one read, like pickers).
    public func current() -> [HostRecord] { hosts }

    public func add(_ draft: HostDraft, key: IntentKey) async throws -> IntentReceipt {
        if let receipt = receipts[key] { return receipt }
        let id = HostID.added(by: key)
        if let refusal = validate(draft, for: id, isNew: true) { return remember(.refused(key: key, reason: refusal.rawValue)) }
        var next = hosts
        next.append(HostRecord(id: id, name: Self.trimmed(draft.name), kind: Self.normalized(draft.kind), reachability: .unknown))
        return await commit(next, key: key)
    }

    public func update(_ id: HostID, with draft: HostDraft, key: IntentKey) async throws -> IntentReceipt {
        if let receipt = receipts[key] { return receipt }
        guard let index = hosts.firstIndex(where: { $0.id == id }) else {
            return remember(.refused(key: key, reason: HostsRefusal.unknownHost.rawValue))
        }
        if let refusal = validate(draft, for: id, isNew: false) { return remember(.refused(key: key, reason: refusal.rawValue)) }
        var next = hosts
        next[index].name = Self.trimmed(draft.name)
        next[index].kind = Self.normalized(draft.kind)
        // A host that stops being SSH can no longer carry others.
        if case .ssh = next[index].kind {} else { Self.clearJumps(to: id, in: &next) }
        return await commit(next, key: key)
    }

    public func remove(_ id: HostID, key: IntentKey) async throws -> IntentReceipt {
        if let receipt = receipts[key] { return receipt }
        guard hosts.contains(where: { $0.id == id }) else {
            return remember(.refused(key: key, reason: HostsRefusal.unknownHost.rawValue))
        }
        var next = hosts.filter { $0.id != id }
        Self.clearJumps(to: id, in: &next)
        return await commit(next, key: key)
    }

    /// Replaces the records with the account's synced set (lane B1). Paired
    /// Macs are dropped and dangling jump references cleared.
    public func applyRemote(_ records: [HostRecord]) {
        var next = records.filter { StoredHost($0) != nil }
        let ids = Set(next.map(\.id))
        for index in next.indices {
            if case .ssh(let endpoint, let jump?) = next[index].kind, !ids.contains(jump) {
                next[index].kind = .ssh(endpoint: endpoint, jumpHost: nil)
            }
        }
        guard next != hosts else { return }
        guard (try? write(next, revision: revision + 1)) != nil else { return }
        hosts = next
        revision += 1
        broadcast()
    }

    // MARK: - Private

    private var snapshot: SourceSnapshot<[HostRecord]> {
        SourceSnapshot(revision: revision, value: hosts, connection: .live(path: nil))
    }

    private func validate(_ draft: HostDraft, for id: HostID, isNew: Bool) -> HostsRefusal? {
        if Self.trimmed(draft.name).isEmpty { return .emptyName }
        switch draft.kind {
        case .pairedMac:
            return .pairedMac
        case .direct(let endpoint):
            return Self.trimmed(endpoint.address).isEmpty ? .emptyAddress : nil
        case .ssh(let endpoint, let jump):
            if Self.trimmed(endpoint.address).isEmpty { return .emptyAddress }
            guard let jump else { return nil }
            if jump == id { return .jumpCycle }
            guard let target = hosts.first(where: { $0.id == jump }), case .ssh = target.kind else { return .unknownJumpHost }
            // Walk the chain from the jump host; reaching `id` is a loop.
            var seen: Set<HostID> = [jump]
            var cursor = target
            while case .ssh(_, let next?) = cursor.kind {
                if next == id { return .jumpCycle }
                guard seen.insert(next).inserted, let host = hosts.first(where: { $0.id == next }) else { break }
                cursor = host
            }
            return nil
        }
    }

    private func commit(_ next: [HostRecord], key: IntentKey) async -> IntentReceipt {
        do {
            try write(next, revision: revision + 1)
        } catch {
            return remember(.refused(key: key, reason: HostsRefusal.storage.rawValue))
        }
        hosts = next
        revision += 1
        let receipt = remember(.committed(key: key, revision: revision))
        broadcast()
        await sync.publish(next, revision: revision)
        return receipt
    }

    private func write(_ records: [HostRecord], revision: UInt64) throws {
        let file = StoredHostsFile(revision: revision, hosts: records.compactMap(StoredHost.init))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: url, options: [.atomic, .completeFileProtection])
    }

    private func broadcast() {
        let snapshot = snapshot
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    @discardableResult
    private func remember(_ receipt: IntentReceipt) -> IntentReceipt {
        if receipts.updateValue(receipt, forKey: receipt.key) == nil {
            receiptOrder.append(receipt.key)
            if receiptOrder.count > Self.receiptMemory {
                receipts[receiptOrder.removeFirst()] = nil
            }
        }
        return receipt
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    private static func clearJumps(to id: HostID, in records: inout [HostRecord]) {
        for index in records.indices {
            if case .ssh(let endpoint, let jump) = records[index].kind, jump == id {
                records[index].kind = .ssh(endpoint: endpoint, jumpHost: nil)
            }
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ kind: HostKind) -> HostKind {
        func clean(_ endpoint: HostEndpoint) -> HostEndpoint {
            let user = endpoint.user.map(trimmed)
            return HostEndpoint(address: trimmed(endpoint.address), port: endpoint.port == 0 ? nil : endpoint.port,
                                user: user?.isEmpty == true ? nil : user)
        }
        switch kind {
        case .pairedMac: return .pairedMac
        case .ssh(let endpoint, let jump): return .ssh(endpoint: clean(endpoint), jumpHost: jump)
        case .direct(let endpoint): return .direct(endpoint: clean(endpoint))
        }
    }
}
