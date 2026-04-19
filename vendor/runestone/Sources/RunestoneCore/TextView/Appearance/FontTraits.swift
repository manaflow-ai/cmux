import Foundation

/// Traits to be applied to a font.
///
/// The font traits can be used with a ``Theme`` to change the appearance of the font when syntax highlighting text.
public struct FontTraits: OptionSet {
    /// Attribute creating a bold font.
    public static let bold = Self(rawValue: 1 << 0)
    /// Attribute creating an italic font.
    public static let italic = Self(rawValue: 1 << 1)

    /// The corresponding value of the raw type.
    public let rawValue: Int

    /// Creates a set of font traits.
    /// - Parameter rawValue: The raw vlaue to create the font traits from.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}
