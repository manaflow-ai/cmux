public import CmuxiOSFeatureKit
public import Foundation

/// The hosts added while signed out (deferred sign-in, e5-extras.md 5),
/// so sign-in can offer to sync them. Client state of this device, JSON in
/// Application Support next to the host records (no secrets).
public actor GuestHostsLedger {
    private let url: URL
    private var ids: [HostID]

    public init(url: URL) {
        self.url = url
        ids = (try? JSONDecoder().decode([HostID].self, from: Data(contentsOf: url))) ?? []
    }

    public func recorded() -> [HostID] { ids }

    public func record(_ id: HostID) {
        guard !ids.contains(id) else { return }
        ids.append(id)
        save()
    }

    public func forget(_ id: HostID) {
        guard ids.contains(id) else { return }
        ids.removeAll { $0 == id }
        save()
    }

    public func clear() {
        ids = []
        try? FileManager.default.removeItem(at: url)
    }

    /// The recorded hosts that still exist, in record order.
    public func pending(in records: [HostRecord]) -> [HostRecord] {
        ids.compactMap { id in records.first { $0.id == id } }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(ids).write(to: url, options: [.atomic, .completeFileProtection])
    }
}
