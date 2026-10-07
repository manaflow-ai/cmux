public import CmuxiOSFeatureKit

/// What a live event changed.
public enum CloudWireChange: Hashable, Sendable {
    case upsert(CloudMachine)
    case removed(machine: String, revision: UInt64)
    /// A snapshot (backup) change or another family: no machine changed.
    case other
    /// A machine change the client cannot decode: resync from a list read.
    case unreadable
}
