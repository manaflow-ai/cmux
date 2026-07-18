import Foundation

/// Contains the protocol-v7 boolean style bits for a render run.
public struct CmuxRenderAttributes: OptionSet, Sendable, Equatable {
    /// The raw protocol bit field.
    public let rawValue: UInt16

    /// Creates attributes from the protocol bit field while retaining future bits.
    /// - Parameter rawValue: The raw protocol-v7 attribute bits.
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Uses a bold font face.
    public static let bold = Self(rawValue: 0x0001)

    /// Uses an italic font face.
    public static let italic = Self(rawValue: 0x0002)

    /// Draws a strikethrough.
    public static let strikethrough = Self(rawValue: 0x0004)

    /// Swaps the resolved foreground and background colors.
    public static let inverse = Self(rawValue: 0x0008)

    /// Dims the foreground.
    public static let dim = Self(rawValue: 0x0010)

    /// Hides the foreground glyphs.
    public static let invisible = Self(rawValue: 0x0020)

    /// Blinks the foreground glyphs.
    public static let blink = Self(rawValue: 0x0040)

    /// Resolves the bit field and underline into renderer-independent presentation flags.
    /// - Parameter underline: The exact underline variant supplied by the server.
    /// - Returns: A presentation value suitable for a native renderer.
    public func style(underline: CmuxRenderUnderline?) -> CmuxRenderStyle {
        CmuxRenderStyle(
            bold: contains(.bold),
            italic: contains(.italic),
            strikethrough: contains(.strikethrough),
            inverse: contains(.inverse),
            dim: contains(.dim),
            invisible: contains(.invisible),
            blink: contains(.blink),
            underline: underline
        )
    }
}
