import Foundation

/// Carries the authoritative cursor state for a render frame.
public struct CmuxRenderCursor: Codable, Sendable, Equatable {
    /// The zero-based viewport column.
    public let x: UInt16

    /// The zero-based viewport row.
    public let y: UInt16

    /// The cursor shape.
    public let style: CmuxRenderCursorStyle

    /// Whether the cursor should blink while focused.
    public let blink: Bool

    /// Whether the cursor is visible in the live viewport.
    public let visible: Bool

    /// The explicit cursor RGB string, or `nil` for normal default treatment.
    public let color: String?

    /// Creates an authoritative cursor value.
    public init(
        x: UInt16,
        y: UInt16,
        style: CmuxRenderCursorStyle,
        blink: Bool,
        visible: Bool,
        color: String?
    ) {
        self.x = x
        self.y = y
        self.style = style
        self.blink = blink
        self.visible = visible
        self.color = color
    }
}
