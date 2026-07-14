import CmuxLiteCore
import GhosttyTerminal

extension CmuxGhosttyViewConfiguration {
    var ghosttyConfiguration: TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontFamily(fontFamily)
            builder.withFontSize(fontSize)
            if let background { builder.withBackground(background) }
            if let foreground { builder.withForeground(foreground) }
            for (index, color) in palette.sorted(by: { $0.key < $1.key }) {
                builder.withPalette(index, color: color)
            }
            builder.withSelectionBackground(selectionBackground ?? "#585858")
            builder.withSelectionForeground(selectionForeground ?? "#eeeeee")
            if let cursorStyle = cursorStyle.flatMap(TerminalCursorStyle.init(rawValue:)) {
                builder.withCursorStyle(cursorStyle)
            }
            if let cursorBlink {
                builder.withCursorStyleBlink(cursorBlink)
            }
        }
    }
}
