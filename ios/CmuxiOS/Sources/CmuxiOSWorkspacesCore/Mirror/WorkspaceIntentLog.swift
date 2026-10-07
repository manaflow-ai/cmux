public import CmuxiOSFeatureKit
public import CmuxMobileWire
import Foundation

/// The ordered log of one host's pending intents. The visible state is
/// the mirror with these applied in order; an intent leaves on its echo
/// (the mirror reached the commit seq), its reject, or when a snapshot
/// lists its key as decided. Never on a timer.
public struct WorkspaceIntentLog: Sendable {
    public private(set) var entries: [PendingWorkspaceIntent] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func append(_ intent: WorkspaceIntent, key: IntentKey) {
        guard !entries.contains(where: { $0.key == key }) else { return }
        entries.append(PendingWorkspaceIntent(key: key, intent: intent))
    }

    /// The owner committed `key` at `seq`. Drops it at once when the mirror
    /// already reached that seq.
    public mutating func committed(_ key: IntentKey, at seq: UInt64, mirrorSeq: UInt64?) {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return }
        if let mirrorSeq, mirrorSeq >= seq {
            entries.remove(at: index)
        } else {
            entries[index].committedAt = seq
        }
    }

    /// Rejected, or the send failed: the intent leaves without effect.
    public mutating func remove(_ key: IntentKey) {
        entries.removeAll { $0.key == key }
    }

    /// The mirror advanced to `seq`: committed intents at or below it are
    /// now part of the confirmed state.
    public mutating func settle(through seq: UInt64) {
        entries.removeAll { entry in entry.committedAt.map { $0 <= seq } ?? false }
    }

    /// A snapshot answered the pending keys it decided.
    public mutating func settle(decided: [DecidedKey], snapshotSeq: UInt64) {
        let keys = Set(decided.map(\.idempotencyKey))
        entries.removeAll { keys.contains($0.key.rawValue) }
        settle(through: snapshotSeq)
    }

    /// The visible workspaces: `confirmed` with every pending intent applied
    /// in order.
    public func overlay(_ confirmed: [WorkspaceSummary]) -> [WorkspaceSummary] {
        entries.reduce(into: confirmed) { workspaces, entry in
            switch entry.intent {
            case .create:
                // The owner picks the id; the row appears with the echo.
                break
            case .rename(let id, let title):
                if let index = workspaces.firstIndex(where: { $0.id == id }) { workspaces[index].title = title }
            case .close(let id):
                workspaces.removeAll { $0.id == id }
            case .markRead(let id):
                guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
                workspaces[index].unreadCount = 0
                for p in workspaces[index].panes.indices {
                    for s in workspaces[index].panes[p].surfaces.indices {
                        workspaces[index].panes[p].surfaces[s].unreadCount = 0
                    }
                }
            }
        }
    }
}
