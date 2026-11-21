import SwiftUI

/// cmux-next's look, kept light: system materials and type, neutral chrome
/// (no tinted accent), and the one cmux highlight blue for primary actions.
/// Values come from `plans/cmux-next/spec-proposals/visuals/design-tokens.json`
/// (Apple System Dark/Light).
struct CmuxTheme {
    /// Send buttons, switches, the plan toggle (`highlight`, ANSI 4).
    static let highlight = Color(red: 0x08 / 255, green: 0x69 / 255, blue: 0xCB / 255)
    static let attention = Color(light: 0xAC9007, dark: 0xCDAC08)
    static let danger = Color(hex: 0xCC372E)
    static let success = Color(hex: 0x26A439)

    /// The terminal background cmux-next ships by default.
    static let terminalBackground = Color(light: 0xFEFFFF, dark: 0x1E1E1E)
    static let chrome = Color(light: 0xF5F6F6, dark: 0x292929)
    static let elevated = Color(light: 0xF9FAFA, dark: 0x2E2E2E)

    static let mono = Font.system(.footnote, design: .monospaced)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Agent harness identity: name, SF Symbol and a quiet tint for avatars.
struct HarnessStyle {
    let name: String
    let symbol: String
    let tint: Color

    static func of(_ harness: String) -> HarnessStyle {
        switch harness {
        case "claude": HarnessStyle(name: "Claude Code", symbol: "sparkle", tint: Color(hex: 0xD97757))
        case "codex": HarnessStyle(name: "Codex", symbol: "hexagon", tint: Color(light: 0x111111, dark: 0xEEEEEE))
        case "gemini": HarnessStyle(name: "Gemini CLI", symbol: "diamond", tint: Color(hex: 0x4F7DF3))
        case "opencode": HarnessStyle(name: "OpenCode", symbol: "chevron.left.forwardslash.chevron.right", tint: .gray)
        default: HarnessStyle(name: harness.capitalized, symbol: "cpu", tint: .gray)
        }
    }
}

extension Date {
    /// "9:41 AM", "Yesterday", "Tuesday", "10/3/26" — the Messages list style.
    var listStamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(self) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return formatted(.dateTime.weekday(.wide))
        }
        return formatted(date: .numeric, time: .omitted)
    }
}
