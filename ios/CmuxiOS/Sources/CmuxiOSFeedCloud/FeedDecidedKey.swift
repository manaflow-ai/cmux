import Foundation

/// A key the owner already decided, as a snapshot reports it.
struct FeedDecidedKey: Hashable, Sendable {
    var key: String
    var ok: Bool
    var sequence: UInt64
}
