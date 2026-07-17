import Foundation

/// Identifies one absolute page requested from retained terminal scrollback.
public struct CmuxScrollbackRequest: Sendable, Equatable {
    /// The zero-based absolute index from the oldest retained row.
    public let start: UInt32

    /// The number of rows requested.
    public let count: UInt32

    /// Creates one scrollback page request.
    public init(start: UInt32, count: UInt32) {
        self.start = start
        self.count = count
    }
}
