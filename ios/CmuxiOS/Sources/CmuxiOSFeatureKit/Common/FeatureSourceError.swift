import Foundation

/// Errors every seam may throw. Owner refusals are receipts, not errors.
public enum FeatureSourceError: Error, Hashable, Sendable {
    /// The owner is unreachable; the change was not sent and nothing queued.
    case offline
    /// The referenced entity is not in the mirror.
    case notFound(String)
    /// The operation is not available on this carrier or build.
    case unsupported(String)
}
