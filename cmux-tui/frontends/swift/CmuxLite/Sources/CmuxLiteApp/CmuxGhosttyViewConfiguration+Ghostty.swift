import CmuxLiteCore
import GhosttyTerminal

extension CmuxGhosttyViewConfiguration {
    var ghosttyConfiguration: TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontFamily(fontFamily)
            builder.withFontSize(fontSize)
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
