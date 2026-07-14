import AppKit
import CmuxLiteCore

struct CmuxTerminalBackgroundColor {
    let color: NSColor

    init(
        colors: CmuxTerminalColors?,
        configuration: CmuxGhosttyViewConfiguration
    ) {
        let source = colors?.background ?? configuration.background
        color = Self.parse(source) ?? .black
    }

    private static func parse(_ value: String?) -> NSColor? {
        guard let value else { return nil }
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        let digits = String(hex.dropFirst())
        guard digits.count == 3 || digits.count == 6 || digits.count == 8,
              let encoded = UInt64(digits, radix: 16)
        else { return nil }

        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64
        switch digits.count {
        case 3:
            red = ((encoded >> 8) & 0xF) * 17
            green = ((encoded >> 4) & 0xF) * 17
            blue = (encoded & 0xF) * 17
            alpha = 0xFF
        case 6:
            red = (encoded >> 16) & 0xFF
            green = (encoded >> 8) & 0xFF
            blue = encoded & 0xFF
            alpha = 0xFF
        default:
            red = (encoded >> 24) & 0xFF
            green = (encoded >> 16) & 0xFF
            blue = (encoded >> 8) & 0xFF
            alpha = encoded & 0xFF
        }
        return NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }
}
