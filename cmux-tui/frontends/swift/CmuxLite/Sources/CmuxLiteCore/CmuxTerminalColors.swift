import Foundation

/// Carries protocol-v6 effective terminal colors and cursor metadata.
public struct CmuxTerminalColors: Decodable, Sendable, Equatable {
    /// Effective foreground color.
    public let foreground: String?

    /// Effective background color.
    public let background: String?

    /// Effective cursor color.
    public let cursor: String?

    /// Effective selection background color.
    public let selectionBackground: String?

    /// Effective selection foreground color.
    public let selectionForeground: String?

    /// Effective cursor shape.
    public let cursorStyle: String?

    /// Whether the cursor blinks.
    public let cursorBlink: Bool?

    enum CodingKeys: String, CodingKey {
        case foreground = "fg"
        case background = "bg"
        case cursor
        case selectionBackground = "selection_bg"
        case selectionForeground = "selection_fg"
        case cursorStyle = "cursor_style"
        case cursorBlink = "cursor_blink"
    }
}
