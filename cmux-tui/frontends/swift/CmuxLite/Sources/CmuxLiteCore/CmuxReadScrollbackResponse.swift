import Foundation

/// Decodes one internally consistent protocol-v7 styled scrollback page.
public struct CmuxReadScrollbackResponse: Codable, Sendable, Equatable {
    /// Rows whose indexes are relative to this page.
    public let rows: [CmuxRenderRow]

    /// The absolute index represented by relative row zero.
    public let start: UInt32

    /// The retained row count captured with this page.
    public let total: UInt32

    /// Creates one styled scrollback page.
    public init(rows: [CmuxRenderRow], start: UInt32, total: UInt32) {
        self.rows = rows
        self.start = start
        self.total = total
    }
}
