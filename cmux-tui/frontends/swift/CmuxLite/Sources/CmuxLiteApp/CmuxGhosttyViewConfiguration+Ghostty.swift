import CmuxLiteCore
import GhosttyTerminal

extension CmuxGhosttyViewConfiguration {
    var ghosttyConfiguration: TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontFamily(fontFamily)
            builder.withFontSize(fontSize)
            if let selectionBackground {
                builder.withSelectionBackground(selectionBackground)
            }
            if let selectionForeground {
                builder.withSelectionForeground(selectionForeground)
            }
            if let cursorStyle = cursorStyle.flatMap(TerminalCursorStyle.init(rawValue:)) {
                builder.withCursorStyle(cursorStyle)
            }
            if let cursorBlink {
                builder.withCursorStyleBlink(cursorBlink)
            }
        }
    }
}
