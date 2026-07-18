import AppKit
import CmuxLiteCore

extension NSEvent {
    var cmuxShortcutInput: CmuxShortcutInput? {
        let key: CmuxShortcutKey
        switch keyCode {
        case 123:
            key = .arrow(.left)
        case 124:
            key = .arrow(.right)
        case 125:
            key = .arrow(.down)
        case 126:
            key = .arrow(.up)
        default:
            guard let character = charactersIgnoringModifiers?.lowercased().first else {
                return nil
            }
            key = .character(character)
        }

        var modifiers: CmuxShortcutModifiers = []
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return CmuxShortcutInput(key: key, modifiers: modifiers)
    }
}
