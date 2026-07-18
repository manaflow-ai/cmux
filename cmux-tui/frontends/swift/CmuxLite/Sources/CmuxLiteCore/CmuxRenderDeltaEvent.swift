import Foundation

/// Decodes one protocol-v7 render frame containing dirty or replacement rows.
public struct CmuxRenderDeltaEvent: Codable, Sendable, Equatable {
    /// The attached surface identifier.
    public let surface: UInt64

    /// The cursor state, present for every frame.
    public let cursor: CmuxRenderCursor

    /// Whether the rows replace the complete viewport.
    public let full: Bool

    /// A new grid when the surface resized.
    public let size: CmuxSurfaceSize?

    /// A changed default foreground RGB string.
    public let defaultForeground: String?

    /// A changed default background RGB string.
    public let defaultBackground: String?

    /// A changed retained scrollback-row count.
    public let scrollbackRows: UInt32?

    /// Dirty rows or the full replacement viewport.
    public let rows: [CmuxRenderRow]

    /// Creates one render delta.
    public init(
        surface: UInt64,
        cursor: CmuxRenderCursor,
        full: Bool,
        size: CmuxSurfaceSize? = nil,
        defaultForeground: String? = nil,
        defaultBackground: String? = nil,
        scrollbackRows: UInt32? = nil,
        rows: [CmuxRenderRow]
    ) {
        self.surface = surface
        self.cursor = cursor
        self.full = full
        self.size = size
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.scrollbackRows = scrollbackRows
        self.rows = rows
    }

    private enum CodingKeys: String, CodingKey {
        case surface
        case cursor
        case full
        case size
        case defaultForeground = "default_fg"
        case defaultBackground = "default_bg"
        case scrollbackRows = "scrollback_rows"
        case rows
    }
}
