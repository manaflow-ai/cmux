import Foundation

/// Represents one zero-based viewport or scrollback row.
public struct CmuxRenderRow: Codable, Sendable, Equatable {
    /// The row index within its containing viewport or page.
    public let row: Int

    /// Ordered styled spans covering the row.
    public let runs: [CmuxRenderRun]

    /// Creates one render row.
    public init(row: Int, runs: [CmuxRenderRun]) {
        self.row = row
        self.runs = runs
    }

    /// Joins the row's plain text runs.
    public var text: String {
        runs.map(\.text).joined()
    }
}
