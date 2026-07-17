import Foundation

/// Represents one maximal span of equally styled terminal cells.
public struct CmuxRenderRun: Codable, Sendable, Equatable {
    /// Plain UTF-8 text for the span.
    public let text: String

    /// The resolved foreground RGB string, or `nil` for the model default.
    public let foreground: String?

    /// The resolved background RGB string, or `nil` for the model default.
    public let background: String?

    /// The protocol boolean style bits.
    public let attributes: CmuxRenderAttributes

    /// The exact underline variant, when present.
    public let underline: CmuxRenderUnderline?

    /// The authoritative number of grid columns covered by the run, when supplied.
    public let widthHint: UInt16?

    /// Creates one styled render run.
    public init(
        text: String,
        foreground: String?,
        background: String?,
        attributes: CmuxRenderAttributes,
        underline: CmuxRenderUnderline? = nil,
        widthHint: UInt16? = nil
    ) {
        self.text = text
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
        self.underline = underline
        self.widthHint = widthHint
    }

    /// Returns the authoritative width hint or a Unicode-width estimate.
    public var cellWidth: Int {
        if let widthHint { return Int(widthHint) }
        return estimatedCellWidth
    }

    /// Estimates the grid width when the server omitted `width_hint`.
    public var estimatedCellWidth: Int {
        text.reduce(into: 0) { width, character in
            width += Self.estimatedCellWidth(of: character)
        }
    }

    /// Estimates the terminal-cell width of one grapheme cluster.
    public static func estimatedCellWidth(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first?.value else { return 1 }
        let wide = (0x1100...0x115F).contains(scalar)
            || (0x2329...0x232A).contains(scalar)
            || (0x2E80...0xA4CF).contains(scalar)
            || (0xAC00...0xD7A3).contains(scalar)
            || (0xF900...0xFAFF).contains(scalar)
            || (0xFE10...0xFE19).contains(scalar)
            || (0xFE30...0xFE6F).contains(scalar)
            || (0xFF00...0xFF60).contains(scalar)
            || (0xFFE0...0xFFE6).contains(scalar)
            || (0x1F300...0x1FAFF).contains(scalar)
            || (0x20000...0x3FFFD).contains(scalar)
        return wide ? 2 : 1
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case foreground = "fg"
        case background = "bg"
        case attributes = "attrs"
        case underline
        case widthHint = "width_hint"
    }
}

extension CmuxRenderAttributes: Codable {
    /// Decodes the raw protocol bit field.
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(UInt16.self))
    }

    /// Encodes the raw protocol bit field.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
