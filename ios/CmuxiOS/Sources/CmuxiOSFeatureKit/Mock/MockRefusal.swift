import Foundation

/// Thrown inside a `MockSnapshotHub` change to refuse it: the value and the
/// revision stay as they were and the caller gets a `.refused` receipt.
public struct MockRefusal: Error, Hashable, Sendable {
    public var reason: String

    public init(_ reason: String) { self.reason = reason }
}
