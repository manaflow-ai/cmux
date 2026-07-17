import Foundation

/// Parses the Ghostty settings that cmux-lite's native renderer consumes.
struct CmuxGhosttyViewConfigurationParser {
    static func parse(_ text: String) -> CmuxGhosttyViewConfiguration {
        parse(text, loadTheme: nil).configuration
    }

    static func parseResolvedOutput(_ text: String) -> CmuxGhosttyViewConfiguration? {
        let result = parse(text, loadTheme: nil)
        return result.foundSupportedSetting ? result.configuration : nil
    }

    static func parse(
        _ text: String,
        loadTheme: ((String) -> String?)?
    ) -> (configuration: CmuxGhosttyViewConfiguration, foundSupportedSetting: Bool) {
        var configuration = CmuxGhosttyViewConfiguration()
        var foundSupportedSetting = false

        for (key, value) in entries(in: text) {
            if key == "theme", let loadTheme,
               let themeText = loadTheme(themeName(for: value))
            {
                let theme = parse(themeText, loadTheme: nil)
                configuration = theme.configuration.merging(into: configuration)
                foundSupportedSetting = foundSupportedSetting || theme.foundSupportedSetting
                continue
            }

            let next = configuration.applying(key: key, value: value)
            if next != configuration {
                foundSupportedSetting = true
            }
            configuration = next
        }
        return (configuration, foundSupportedSetting)
    }

    private static func entries(in text: String) -> [(String, String)] {
        text.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "="),
                  let value = unquoted(line[line.index(after: separator)...])
            else { return nil }
            return (line[..<separator].trimmingCharacters(in: .whitespaces), value)
        }
    }

    private static func themeName(for value: String) -> String {
        let variants = value.split(separator: ",", omittingEmptySubsequences: false)
        if let dark = variants.first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("dark:")
        }) {
            return String(dark.trimmingCharacters(in: .whitespaces).dropFirst(5))
                .trimmingCharacters(in: .whitespaces)
        }
        return value
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
}

private extension CmuxGhosttyViewConfiguration {
    func applying(key: String, value: String) -> CmuxGhosttyViewConfiguration {
        var fontFamily = fontFamily
        var fontSize = fontSize
        var background = background
        var foreground = foreground
        var palette = palette
        var selectionBackground = selectionBackground
        var selectionForeground = selectionForeground
        var cursorStyle = cursorStyle
        var cursorBlink = cursorBlink

        switch key {
        case "font-family":
            guard !value.isEmpty else { return self }
            fontFamily = value
        case "font-size":
            guard let parsed = Float(value), parsed.isFinite, parsed > 0, parsed <= 512 else {
                return self
            }
            fontSize = parsed
        case "background":
            guard Self.isGhosttyColor(value) else { return self }
            background = value
        case "foreground":
            guard Self.isGhosttyColor(value) else { return self }
            foreground = value
        case "palette":
            guard let paletteEntry = Self.paletteEntry(value) else { return self }
            palette[paletteEntry.index] = paletteEntry.color
        case "selection-background":
            guard Self.isGhosttyColor(value) else { return self }
            selectionBackground = value
        case "selection-foreground":
            guard Self.isGhosttyColor(value) else { return self }
            selectionForeground = value
        case "cursor-style":
            guard ["block", "bar", "underline"].contains(value) else { return self }
            cursorStyle = value
        case "cursor-style-blink":
            guard value == "true" || value == "false" else { return self }
            cursorBlink = value == "true"
        default:
            return self
        }

        return CmuxGhosttyViewConfiguration(
            fontFamily: fontFamily,
            fontSize: fontSize,
            background: background,
            foreground: foreground,
            palette: palette,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            cursorStyle: cursorStyle,
            cursorBlink: cursorBlink
        )
    }

    func merging(into base: CmuxGhosttyViewConfiguration) -> CmuxGhosttyViewConfiguration {
        CmuxGhosttyViewConfiguration(
            fontFamily: fontFamily == Self.fallbackFontFamily ? base.fontFamily : fontFamily,
            fontSize: fontSize == Self.fallbackFontSize ? base.fontSize : fontSize,
            background: background ?? base.background,
            foreground: foreground ?? base.foreground,
            palette: base.palette.merging(palette, uniquingKeysWith: { _, latest in latest }),
            selectionBackground: selectionBackground ?? base.selectionBackground,
            selectionForeground: selectionForeground ?? base.selectionForeground,
            cursorStyle: cursorStyle ?? base.cursorStyle,
            cursorBlink: cursorBlink ?? base.cursorBlink
        )
    }

    static func paletteEntry(_ value: String) -> (index: Int, color: String)? {
        guard let separator = value.firstIndex(of: "="),
              let index = Int(value[..<separator]),
              (0...255).contains(index)
        else { return nil }
        let color = String(value[value.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard isGhosttyColor(color) else { return nil }
        return (index, color)
    }

    static func isGhosttyColor(_ value: String) -> Bool {
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

        return !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }
    }
}
