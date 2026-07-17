import Foundation

/// A terminal grid size expressed in character cells.
public struct CmuxSurfaceSize: Codable, Sendable, Equatable {
    /// The number of terminal columns.
    public let cols: UInt16

    /// The number of terminal rows.
    public let rows: UInt16

    /// Creates a terminal grid size.
    /// - Parameters:
    ///   - cols: The number of terminal columns.
    ///   - rows: The number of terminal rows.
    public init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }
}
