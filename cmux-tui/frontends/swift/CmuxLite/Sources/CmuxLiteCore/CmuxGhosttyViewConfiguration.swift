import Foundation

/// Holds Ghostty font and fallback-color preferences used by the native renderer.
public struct CmuxGhosttyViewConfiguration: Sendable, Equatable {
    /// The fallback monospace family used when no valid preference exists.
    public static let fallbackFontFamily = "Menlo"

    /// The fallback point size used when no valid preference exists.
    public static let fallbackFontSize: Float = 13

    /// The preferred font family.
    public let fontFamily: String

    /// The preferred font size in points.
    public let fontSize: Float

    /// The resolved terminal background using Ghostty color syntax.
    public let background: String?

    /// The resolved terminal foreground using Ghostty color syntax.
    public let foreground: String?

    /// Resolved ANSI palette entries keyed by their 0...255 index.
    public let palette: [Int: String]

    /// The preferred selection background using Ghostty color syntax.
    public let selectionBackground: String?

    /// The preferred selection foreground using Ghostty color syntax.
    public let selectionForeground: String?

    /// The default cursor style: `block`, `bar`, or `underline`.
    public let cursorStyle: String?

    /// Whether the default cursor blinks.
    public let cursorBlink: Bool?

    /// Creates an explicit view configuration.
    /// - Parameters:
    ///   - fontFamily: A non-empty font family.
    ///   - fontSize: A positive finite point size.
    ///   - background: An optional terminal background.
    ///   - foreground: An optional terminal foreground.
    ///   - palette: Optional ANSI palette overrides.
    ///   - selectionBackground: An optional Ghostty selection background.
    ///   - selectionForeground: An optional Ghostty selection foreground.
    ///   - cursorStyle: An optional Ghostty cursor style.
    ///   - cursorBlink: An optional Ghostty cursor blink default.
    public init(
        fontFamily: String = Self.fallbackFontFamily,
        fontSize: Float = Self.fallbackFontSize,
        background: String? = nil,
        foreground: String? = nil,
        palette: [Int: String] = [:],
        selectionBackground: String? = nil,
        selectionForeground: String? = nil,
        cursorStyle: String? = nil,
        cursorBlink: Bool? = nil
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.background = background
        self.foreground = foreground
        self.palette = palette
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
    }

    /// Returns the requested Ghostty config path beneath a home directory.
    /// - Parameter homeDirectory: The current user's home directory.
    /// - Returns: `~/.config/ghostty/config`.
    public static func configPath(homeDirectory: String) -> String {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".config/ghostty/config", isDirectory: false)
            .path
    }

    /// Parses direct Ghostty settings without resolving theme references.
    ///
    /// Later valid entries win. Unknown keys and malformed values are ignored.
    /// Matching single or double quotes around values are removed.
    ///
    /// - Parameter text: Ghostty configuration file contents.
    /// - Returns: Parsed values with stable font fallbacks.
    public static func parse(_ text: String) -> CmuxGhosttyViewConfiguration {
        CmuxGhosttyViewConfigurationParser.parse(text)
    }

    /// Parses the fully resolved text emitted by `ghostty +show-config`.
    ///
    /// - Parameter text: The command's resolved configuration output.
    /// - Returns: A configuration when at least one supported resolved setting was present.
    public static func parseResolvedOutput(_ text: String) -> CmuxGhosttyViewConfiguration? {
        CmuxGhosttyViewConfigurationParser.parseResolvedOutput(text)
    }

    /// Parses a Ghostty config while resolving only loadable theme references.
    ///
    /// The loader lets the app supply Ghostty's theme search order without making
    /// the core model depend on the filesystem. A missing theme is ignored so a
    /// later invalid line cannot erase an earlier resolved theme.
    ///
    /// - Parameters:
    ///   - text: The Ghostty configuration file contents.
    ///   - loadTheme: Returns the theme file contents for a loadable theme name.
    /// - Returns: Parsed values with stable font fallbacks.
    public static func parseFallback(
        _ text: String,
        loadTheme: @escaping (String) -> String?
    ) -> CmuxGhosttyViewConfiguration {
        CmuxGhosttyViewConfigurationParser.parse(text, loadTheme: loadTheme).configuration
    }
}
