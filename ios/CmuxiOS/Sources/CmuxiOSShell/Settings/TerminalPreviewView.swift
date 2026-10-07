import CmuxiOSSettingsCore
import CmuxTheme
import SwiftUI
import UIKit

/// A few terminal lines in the chosen theme, font, size and cursor. "Match
/// Mac" previews Ghostty's default colors. Decorative for VoiceOver, which
/// reads one summary instead.
struct TerminalPreviewView: View {
    let preferences: TerminalPreferences

    var body: some View {
        let theme = preferences.theme.themeInput ?? .ghosttyDefault
        VStack(alignment: .leading, spacing: 2) {
            line([("~/cmux", color(theme, 4)), (" $ ", color(theme, 8)), ("swift test", foreground(theme))])
            line([("✓ ", color(theme, 2)), ("214 tests passed", foreground(theme))])
            line([("! ", color(theme, 3)), ("1 warning", color(theme, 3)), (" in Package.swift", color(theme, 8))])
            HStack(spacing: 0) {
                line([("~/cmux", color(theme, 4)), (" $ ", color(theme, 8))])
                cursor(theme)
            }
        }
        .font(font)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(theme.background))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SettingsText.previewLabel)
        .accessibilityValue(SettingsText.previewValue(preferences))
    }

    private var font: Font {
        let size = preferences.fontSize
        if let family = preferences.font.ghosttyFamily {
            return preferences.followsDynamicType
                ? .custom(family, size: size, relativeTo: .body)
                : .custom(family, fixedSize: size)
        }
        let scaled = preferences.followsDynamicType ? UIFontMetrics(forTextStyle: .body).scaledValue(for: size) : size
        return .system(size: scaled, design: .monospaced)
    }

    private func line(_ runs: [(String, Color)]) -> some View {
        runs.reduce(Text("")) { text, run in text + Text(run.0).foregroundColor(run.1) }
            .lineLimit(1)
    }

    @ViewBuilder private func cursor(_ theme: ThemeInput) -> some View {
        let ink = foreground(theme)
        switch preferences.cursorStyle {
        case .block: Text(" ").background(ink)
        case .bar: Text(" ").overlay(alignment: .leading) { Rectangle().fill(ink).frame(width: 2) }
        case .underline: Text(" ").overlay(alignment: .bottom) { Rectangle().fill(ink).frame(height: 2) }
        }
    }

    private func foreground(_ theme: ThemeInput) -> Color { Color(theme.foreground) }

    private func color(_ theme: ThemeInput, _ index: Int) -> Color {
        theme.palette.indices.contains(index) ? Color(theme.palette[index]) : Color(theme.foreground)
    }
}
