import Foundation

/// Holds Ghostty preferences that a remote byte stream cannot fully configure in-band.
public struct CmuxGhosttyViewConfiguration: Sendable, Equatable {
    /// The fallback monospace family used when no valid preference exists.
    public static let fallbackFontFamily = "Menlo"

    /// The fallback point size used when no valid preference exists.
    public static let fallbackFontSize: Float = 13

    /// The preferred font family.
    public let fontFamily: String

    /// The preferred font size in points.
    public let fontSize: Float

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
    ///   - selectionBackground: An optional Ghostty selection background.
    ///   - selectionForeground: An optional Ghostty selection foreground.
    ///   - cursorStyle: An optional Ghostty cursor style.
    ///   - cursorBlink: An optional Ghostty cursor blink default.
    public init(
        fontFamily: String = Self.fallbackFontFamily,
        fontSize: Float = Self.fallbackFontSize,
        selectionBackground: String? = nil,
        selectionForeground: String? = nil,
        cursorStyle: String? = nil,
        cursorBlink: Bool? = nil
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
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

    /// Parses the supported subset of Ghostty's `key = value` format.
    ///
    /// Later valid entries win. Unknown keys and malformed values are ignored.
    /// Matching single or double quotes around values are removed.
    ///
    /// - Parameter text: Ghostty configuration file contents.
    /// - Returns: Parsed values with stable font fallbacks.
    public static func parse(_ text: String) -> CmuxGhosttyViewConfiguration {
        var fontFamily = fallbackFontFamily
        var fontSize = fallbackFontSize
        var selectionBackground: String?
        var selectionForeground: String?
        var cursorStyle: String?
        var cursorBlink: Bool?

        for rawLine in text.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "=")
            else { continue }

            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: separator)...]
            guard let value = unquoted(rawValue) else { continue }

            switch key {
            case "font-family":
                if !value.isEmpty { fontFamily = value }
            case "font-size":
                if let parsed = Float(value), parsed.isFinite, parsed > 0, parsed <= 512 {
                    fontSize = parsed
                }
            case "selection-background":
                if isGhosttyColor(value) { selectionBackground = value }
            case "selection-foreground":
                if isGhosttyColor(value) { selectionForeground = value }
            case "cursor-style":
                if ["block", "bar", "underline"].contains(value) {
                    cursorStyle = value
                }
            case "cursor-style-blink":
                if value == "true" {
                    cursorBlink = true
                } else if value == "false" {
                    cursorBlink = false
                }
            default:
                break
            }
        }

        return CmuxGhosttyViewConfiguration(
            fontFamily: fontFamily,
            fontSize: fontSize,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            cursorStyle: cursorStyle,
            cursorBlink: cursorBlink
        )
    }

    private static func unquoted(_ rawValue: Substring) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        guard let first = value.first else { return "" }
        if first == "\"" || first == "'" {
            guard value.count >= 2, value.last == first else { return nil }
            return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard value.last != "\"", value.last != "'" else { return nil }
        return value
    }

    private static func isGhosttyColor(_ value: String) -> Bool {
        if value == "cell-foreground" || value == "cell-background" {
            return true
        }

        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if [3, 6, 9, 12].contains(hex.count),
           hex.unicodeScalars.allSatisfy({ scalar in
               (48...57).contains(scalar.value)
                   || (65...70).contains(scalar.value)
                   || (97...102).contains(scalar.value)
           })
        {
            return true
        }

        // Ghostty also accepts X11 color names. Their syntax is alphanumeric
        // words with optional spaces; Ghostty performs the final name lookup.
        return !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }
    }
}
