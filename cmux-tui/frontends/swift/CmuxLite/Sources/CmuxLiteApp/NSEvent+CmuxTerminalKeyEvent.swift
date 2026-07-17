import AppKit
import CmuxLiteCore

extension NSEvent {
    var cmuxTerminalKeyEvent: CmuxTerminalKeyEvent? {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key: String
        switch keyCode {
        case 36, 76: key = "Enter"
        case 48: key = "Tab"
        case 53: key = "Escape"
        case 51: key = "Backspace"
        case 117: key = "Delete"
        case 114: key = "Insert"
        case 126: key = "ArrowUp"
        case 125: key = "ArrowDown"
        case 123: key = "ArrowLeft"
        case 124: key = "ArrowRight"
        case 115: key = "Home"
        case 119: key = "End"
        case 116: key = "PageUp"
        case 121: key = "PageDown"
        case 122: key = "F1"
        case 120: key = "F2"
        case 99: key = "F3"
        case 118: key = "F4"
        case 96: key = "F5"
        case 97: key = "F6"
        case 98: key = "F7"
        case 100: key = "F8"
        case 101: key = "F9"
        case 109: key = "F10"
        case 103: key = "F11"
        case 111: key = "F12"
        default:
            guard let characters = CmuxTerminalKeyEvent.adaptedCharacters(
                characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers,
                control: flags.contains(.control)
            ) else { return nil }
            key = characters
        }
        return CmuxTerminalKeyEvent(
            key: key,
            control: flags.contains(.control),
            option: flags.contains(.option),
            shift: flags.contains(.shift),
            command: flags.contains(.command),
            composing: false
        )
    }
}
