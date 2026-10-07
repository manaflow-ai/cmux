import Foundation

/// One coalesced view of an owner's state as a feature screen renders it.
///
/// Every seam in this module streams snapshots, never raw deltas: the real
/// implementation applies owner events to its mirror, resyncs on a revision
/// gap, overlays pending intents, and yields at most one snapshot per change
/// batch. Screens diff snapshots by stable ids.
public struct SourceSnapshot<Value: Sendable>: Sendable {
    /// The owner revision this snapshot reflects. Monotonic per stream.
    public var revision: UInt64
    public var value: Value
    public var connection: SourceConnection

    public init(revision: UInt64, value: Value, connection: SourceConnection) {
        self.revision = revision
        self.value = value
        self.connection = connection
    }
}

extension SourceSnapshot: Equatable where Value: Equatable {}
