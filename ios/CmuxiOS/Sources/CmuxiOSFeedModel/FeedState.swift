public import CmuxiOSFeatureKit
import Foundation

/// The confirmed mirror plus the ordered intent log (pure). The visible feed
/// is the mirror with every pending intent applied in order; when the log is
/// empty the visible feed equals the owner's state (invariant 4).
public struct FeedState: Sendable {
    public private(set) var confirmed: SourceSnapshot<[FeedItem]>?
    public private(set) var pending: [FeedPendingIntent] = []

    public init(confirmed: SourceSnapshot<[FeedItem]>? = nil) {
        self.confirmed = confirmed
    }

    public var connection: SourceConnection { confirmed?.connection ?? .connecting }
    public var revision: UInt64 { confirmed?.revision ?? 0 }

    /// Mirror + pending intents.
    public func visibleItems(device: String?) -> [FeedItem] {
        var items = confirmed?.value ?? []
        for entry in pending { entry.intent.apply(to: &items, at: entry.at, device: device) }
        return items
    }

    /// A new owner snapshot; retires intents the mirror now covers.
    public mutating func receive(_ snapshot: SourceSnapshot<[FeedItem]>) {
        confirmed = snapshot
        retire()
    }

    public mutating func enqueue(_ entry: FeedPendingIntent) {
        pending.removeAll { $0.key == entry.key }
        pending.append(entry)
    }

    /// The owner's receipt: a refusal leaves the log at once; a commit
    /// leaves it when the mirror reaches the commit's revision.
    public mutating func settle(_ receipt: IntentReceipt) {
        switch receipt {
        case .refused(let key, _):
            drop(key)
        case .committed(let key, let revision):
            guard let index = pending.firstIndex(where: { $0.key == key }) else { return }
            pending[index].committedAt = revision
            retire()
        }
    }

    /// Not sent (offline or a transport failure): leaves the log.
    public mutating func drop(_ key: IntentKey) {
        pending.removeAll { $0.key == key }
    }

    public func isPending(_ itemID: FeedItem.ID) -> Bool {
        pending.contains { entry in
            switch entry.intent {
            case .answer(let id, _), .decline(let id): id == itemID
            default: false
            }
        }
    }

    private mutating func retire() {
        let current = revision
        pending.removeAll { entry in entry.committedAt.map { $0 <= current } ?? false }
    }
}
