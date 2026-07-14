import CmuxLiteCore
import GhosttyTerminal

extension CmuxTerminalColors {
    var ghosttyConfiguration: TerminalConfiguration {
        TerminalConfiguration { builder in
            if let foreground { builder.withForeground(foreground) }
            if let background { builder.withBackground(background) }
            if let cursor { builder.withCursorColor(cursor) }
            if let selectionBackground { builder.withSelectionBackground(selectionBackground) }
            if let selectionForeground { builder.withSelectionForeground(selectionForeground) }
            if let cursorBlink { builder.withCursorStyleBlink(cursorBlink) }
            if let cursorStyle = cursorStyle.flatMap(TerminalCursorStyle.init(rawValue:)) {
                builder.withCursorStyle(cursorStyle)
            }
        }
    }
}
