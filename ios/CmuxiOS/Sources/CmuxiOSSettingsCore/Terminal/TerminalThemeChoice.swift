public import CmuxTheme

/// The terminal theme picked in Settings. `matchMac` keeps the theme the
/// terminal was opened with (the Mac's, synced by the session host).
public enum TerminalThemeChoice: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case matchMac
    case ghosttyDefault
    case monokai
    case paper
    case ink

    public var id: String { rawValue }

    /// The colors the renderer uses; nil for `matchMac`.
    public var themeInput: ThemeInput? {
        switch self {
        case .matchMac: nil
        case .ghosttyDefault: .ghosttyDefault
        case .monokai: ThemeInput(terminalTheme: .monokai)
        case .paper: Self.paperTheme
        case .ink: Self.inkTheme
        }
    }

    /// A light theme: warm paper, near-black ink, Tomorrow's ANSI colors.
    private static let paperTheme = ThemeInput(
        background: ThemeRGB(hex: 0xFAFAF7),
        foreground: ThemeRGB(hex: 0x1F1F1F),
        palette: [
            0x1D1F21, 0xC82829, 0x718C00, 0xB58900, 0x4271AE, 0x8959A8, 0x3E999F, 0x8E908C,
            0x5A5B5E, 0xC82829, 0x718C00, 0xB58900, 0x4271AE, 0x8959A8, 0x3E999F, 0x1F1F1F,
        ].map { ThemeRGB(hex: $0) },
        selectionBackground: ThemeRGB(hex: 0xDADAD4)
    )

    /// A dark theme: near-black, soft white, Tomorrow Night's ANSI colors.
    private static let inkTheme = ThemeInput(
        background: ThemeRGB(hex: 0x0E0E10),
        foreground: ThemeRGB(hex: 0xE6E6E6),
        palette: ThemeInput.ghosttyDefault.palette,
        selectionBackground: ThemeRGB(hex: 0x3A3A3E)
    )
}
