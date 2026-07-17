import AppKit

struct CmuxRenderColor {
    let color: NSColor

    init?(_ value: String?) {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let digits = String(trimmed.dropFirst())
        guard [3, 6, 8].contains(digits.count), let encoded = UInt64(digits, radix: 16) else {
            return nil
        }

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
        color = NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }
}
