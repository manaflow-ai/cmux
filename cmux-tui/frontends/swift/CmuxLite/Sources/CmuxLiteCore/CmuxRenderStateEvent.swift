import Foundation

/// Decodes a complete protocol-v7 render viewport snapshot.
public struct CmuxRenderStateEvent: Codable, Sendable, Equatable {
    /// The attached surface identifier.
    public let surface: UInt64

    /// The complete authoritative grid.
    public let size: CmuxSurfaceSize

    /// The authoritative cursor state.
    public let cursor: CmuxRenderCursor

    /// The default foreground RGB string.
    public let defaultForeground: String

    /// The default background RGB string.
    public let defaultBackground: String

    /// The retained styled-row count above the live viewport.
    public let scrollbackRows: UInt32

    /// The complete viewport rows.
    public let rows: [CmuxRenderRow]

    /// Creates a complete render snapshot.
    public init(
        surface: UInt64,
        size: CmuxSurfaceSize,
        cursor: CmuxRenderCursor,
        defaultForeground: String,
        defaultBackground: String,
        scrollbackRows: UInt32,
        rows: [CmuxRenderRow]
    ) {
        self.surface = surface
        self.size = size
        self.cursor = cursor
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.scrollbackRows = scrollbackRows
        self.rows = rows
    }

    private enum CodingKeys: String, CodingKey {
        case surface
        case size
        case cursor
        case defaultForeground = "default_fg"
        case defaultBackground = "default_bg"
        case scrollbackRows = "scrollback_rows"
        case rows
    }
}
