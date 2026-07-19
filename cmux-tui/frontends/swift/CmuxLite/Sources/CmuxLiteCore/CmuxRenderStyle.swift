import Foundation

/// Describes renderer-independent presentation resolved from a protocol run.
public struct CmuxRenderStyle: Sendable, Equatable {
    /// Whether the font is bold.
    public let bold: Bool

    /// Whether the font is italic.
    public let italic: Bool

    /// Whether the run is struck through.
    public let strikethrough: Bool

    /// Whether foreground and background are swapped.
    public let inverse: Bool

    /// Whether the foreground is dimmed.
    public let dim: Bool

    /// Whether glyphs are hidden.
    public let invisible: Bool

    /// Whether glyphs blink.
    public let blink: Bool

    /// The exact underline variant, when present.
    public let underline: CmuxRenderUnderline?

    /// Creates a fully resolved presentation value.
    public init(
        bold: Bool,
        italic: Bool,
        strikethrough: Bool,
        inverse: Bool,
        dim: Bool,
        invisible: Bool,
        blink: Bool,
        underline: CmuxRenderUnderline?
    ) {
        self.bold = bold
        self.italic = italic
        self.strikethrough = strikethrough
        self.inverse = inverse
        self.dim = dim
        self.invisible = invisible
        self.blink = blink
        self.underline = underline
    }
}
