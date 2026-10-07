public import CmuxTerminalRenderCore
import Foundation

/// The terminal settings of this device (client state, never synced).
/// Decoding is tolerant: an unknown or missing value reads as its default,
/// so a newer or older build never loses the rest.
public struct TerminalPreferences: Hashable, Sendable, Codable {
    /// Base font size range in points (at the default Dynamic Type size).
    public static let fontSizeRange: ClosedRange<Double> = 9...24
    public static let defaultFontSize: Double = 13

    public var theme: TerminalThemeChoice
    public var font: TerminalFontChoice
    public var fontSize: Double
    public var followsDynamicType: Bool
    public var cursorStyle: TerminalCursorStyle
    public var cursorBlink: Bool
    /// Keys shown on the key bar, in order. Never empty after `normalized()`.
    public var keyBarKeys: [KeyBarKeyID]

    public init(theme: TerminalThemeChoice = .matchMac, font: TerminalFontChoice = .standard,
                fontSize: Double = Self.defaultFontSize, followsDynamicType: Bool = true,
                cursorStyle: TerminalCursorStyle = .block, cursorBlink: Bool = false,
                keyBarKeys: [KeyBarKeyID] = KeyBarKeyID.defaultOrder) {
        self.theme = theme
        self.font = font
        self.fontSize = fontSize
        self.followsDynamicType = followsDynamicType
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.keyBarKeys = keyBarKeys
    }

    /// Font size clamped and rounded to whole points; key bar without
    /// duplicates, and the default bar when empty.
    public func normalized() -> TerminalPreferences {
        var next = self
        let size = fontSize.isFinite ? fontSize.rounded() : Self.defaultFontSize
        next.fontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        var seen = Set<KeyBarKeyID>()
        next.keyBarKeys = keyBarKeys.filter { seen.insert($0).inserted }
        if next.keyBarKeys.isEmpty { next.keyBarKeys = KeyBarKeyID.defaultOrder }
        return next
    }

    /// What the renderer applies.
    public var appearance: TerminalAppearance {
        let value = normalized()
        return TerminalAppearance(
            theme: value.theme.themeInput,
            fontFamily: value.font.ghosttyFamily,
            baseFontSize: value.fontSize,
            followsDynamicType: value.followsDynamicType,
            cursorStyle: value.cursorStyle,
            cursorBlink: value.cursorBlink,
            keyBarKeyIDs: value.keyBarKeys.map(\.rawValue)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case theme, font, fontSize, followsDynamicType, cursorStyle, cursorBlink, keyBarKeys
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TerminalPreferences()
        func raw(_ key: CodingKeys) -> String? { try? container.decodeIfPresent(String.self, forKey: key) }
        theme = raw(.theme).flatMap(TerminalThemeChoice.init(rawValue:)) ?? defaults.theme
        font = raw(.font).flatMap(TerminalFontChoice.init(rawValue:)) ?? defaults.font
        fontSize = (try? container.decodeIfPresent(Double.self, forKey: .fontSize)) ?? defaults.fontSize
        followsDynamicType = (try? container.decodeIfPresent(Bool.self, forKey: .followsDynamicType))
            ?? defaults.followsDynamicType
        cursorStyle = raw(.cursorStyle).flatMap(TerminalCursorStyle.init(rawValue:)) ?? defaults.cursorStyle
        cursorBlink = (try? container.decodeIfPresent(Bool.self, forKey: .cursorBlink)) ?? defaults.cursorBlink
        let ids = (try? container.decodeIfPresent([String].self, forKey: .keyBarKeys)) ?? nil
        keyBarKeys = ids.map { $0.compactMap(KeyBarKeyID.init(rawValue:)) } ?? defaults.keyBarKeys
        self = normalized()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(theme.rawValue, forKey: .theme)
        try container.encode(font.rawValue, forKey: .font)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(followsDynamicType, forKey: .followsDynamicType)
        try container.encode(cursorStyle.rawValue, forKey: .cursorStyle)
        try container.encode(cursorBlink, forKey: .cursorBlink)
        try container.encode(keyBarKeys.map(\.rawValue), forKey: .keyBarKeys)
    }
}
