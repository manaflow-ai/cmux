import CmuxiOSFeatureKit
import Foundation

/// The confirmed copy of the owner's items at a revision (pure). Written
/// only from owner frames: a snapshot replaces it, an event at the next
/// revision updates it, anything else is a duplicate or a gap.
struct FeedMirror: Sendable {
    enum EventResult: Equatable, Sendable {
        case applied
        /// At or below the mirror's revision: already applied.
        case duplicate
        /// A revision was skipped: the mirror needs a snapshot.
        case gap
    }

    private(set) var items: [String: FeedItem] = [:]
    private(set) var revision: UInt64 = 0
    /// False until the first snapshot and after a gap, until the next one.
    private(set) var isCurrent = false

    mutating func apply(snapshot seq: UInt64, items: [FeedItem]) {
        self.items = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        revision = seq
        isCurrent = true
    }

    mutating func apply(event seq: UInt64, items changed: [FeedItem], present: [String]?) -> EventResult {
        guard isCurrent else { return .gap }
        if seq <= revision { return .duplicate }
        guard seq == revision + 1 else {
            isCurrent = false
            return .gap
        }
        for item in changed { items[item.id] = item }
        if let present {
            let keep = Set(present)
            items = items.filter { keep.contains($0.key) }
        }
        revision = seq
        return .applied
    }

    mutating func invalidate() { isCurrent = false }

    /// Display order is the screen's job; this is stable for diffing.
    var sortedItems: [FeedItem] { items.values.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) } }
}
