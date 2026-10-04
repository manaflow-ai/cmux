import Foundation

/// Modifier keys of one key event, independent of UIKit and Ghostty.
public struct TerminalKeyMods: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = TerminalKeyMods(rawValue: 1 << 0)
    public static let control = TerminalKeyMods(rawValue: 1 << 1)
    public static let alternate = TerminalKeyMods(rawValue: 1 << 2)
    public static let command = TerminalKeyMods(rawValue: 1 << 3)
}

/// One key event for Ghostty's encoder (`ghostty_surface_key`): the physical
/// key as a mac virtual key code (the iOS native code, KB4), the modifiers,
/// the text the key produces (nil lets the encoder derive it) and the key's
/// unshifted codepoint. The app never turns a key into bytes itself (D5).
public struct TerminalKeyEvent: Hashable, Sendable {
    public var keyCode: UInt32
    public var mods: TerminalKeyMods
    public var text: String?
    public var unshiftedCodepoint: UInt32
    public var isPress: Bool

    public init(keyCode: UInt32, mods: TerminalKeyMods = [], text: String? = nil, unshiftedCodepoint: UInt32 = 0,
                isPress: Bool = true) {
        self.keyCode = keyCode
        self.mods = mods
        self.text = text
        self.unshiftedCodepoint = unshiftedCodepoint
        self.isPress = isPress
    }

    /// The release of this press.
    public var released: TerminalKeyEvent {
        var copy = self
        copy.isPress = false
        copy.text = nil
        return copy
    }
}

/// What the terminal view sends to Ghostty for one input step.
public enum TerminalInputAction: Hashable, Sendable {
    /// A key press or release (`ghostty_surface_key`).
    case key(TerminalKeyEvent)
    /// Committed text, as typed (`ghostty_surface_text_input`: no bracketed
    /// paste, LF becomes CR).
    case text(String)
    /// A paste (`ghostty_surface_text`: bracketed paste when the app asked for it).
    case paste(String)
    /// The input method's marked text, drawn at the cursor and never sent
    /// (`ghostty_surface_preedit`); empty clears it.
    case preedit(String)
}

/// Physical keys by HID usage (page 7) that the router names.
public enum TerminalHIDUsage {
    public static let enter: UInt16 = 0x28
    public static let escape: UInt16 = 0x29
    public static let backspace: UInt16 = 0x2A
    public static let tab: UInt16 = 0x2B
    public static let space: UInt16 = 0x2C
    public static let insert: UInt16 = 0x49
    public static let home: UInt16 = 0x4A
    public static let pageUp: UInt16 = 0x4B
    public static let forwardDelete: UInt16 = 0x4C
    public static let end: UInt16 = 0x4D
    public static let pageDown: UInt16 = 0x4E
    public static let right: UInt16 = 0x4F
    public static let left: UInt16 = 0x50
    public static let down: UInt16 = 0x51
    public static let up: UInt16 = 0x52
    public static let keypadEnter: UInt16 = 0x58

    /// Keys that type no text: they always go to Ghostty's encoder.
    public static func isSpecial(_ usage: UInt16) -> Bool {
        switch usage {
        case enter, escape, backspace, tab, keypadEnter, insert...up: true
        case 0x3A...0x45, 0x68...0x73: true // F1-F12, F13-F24
        default: false
        }
    }

    /// The physical key of an ASCII character on a US layout, for keys the
    /// software keyboard or the key bar sends with a sticky modifier.
    public static func usage(forASCII character: Character) -> UInt16? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return nil }
        switch scalar.value {
        case 0x61...0x7A: return UInt16(0x04 + scalar.value - 0x61) // a-z
        case 0x41...0x5A: return UInt16(0x04 + scalar.value - 0x41) // A-Z
        case 0x31...0x39: return UInt16(0x1E + scalar.value - 0x31) // 1-9
        case 0x30: return 0x27 // 0
        default: return asciiPunctuation[scalar.value]
        }
    }

    private static let asciiPunctuation: [UInt32: UInt16] = [
        0x20: space, 0x2D: 0x2D, 0x3D: 0x2E, 0x5B: 0x2F, 0x5D: 0x30, 0x5C: 0x31, 0x3B: 0x33, 0x27: 0x34,
        0x60: 0x35, 0x2C: 0x36, 0x2E: 0x37, 0x2F: 0x38,
    ]

    /// The mac virtual key code of a HID usage (0xFFFF when Ghostty has none).
    public static func macKeyCode(_ usage: UInt16) -> UInt32 {
        TerminalPhysicalKeys.macKeyCode[usage] ?? 0xFFFF
    }
}
