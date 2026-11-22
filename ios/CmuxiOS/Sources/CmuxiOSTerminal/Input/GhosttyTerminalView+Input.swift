import Foundation
import GhosttyNextKit
import UIKit

/// Runs the router's actions on the Ghostty surface: keys through the key
/// encoder, committed text as typed, pastes as pastes, marked text as preedit.
/// Ghostty writes the encoded bytes to `io_write_cb` on this thread (D6),
/// which reaches `onInput`.
extension GhosttyTerminalView {
    func perform(_ actions: [TerminalInputAction]) {
        guard let surface else { return }
        for action in actions {
            switch action {
            case .key(let event):
                Self.withCString(event.text) { text in
                    var key = ghostty_input_key_s()
                    key.action = event.isPress ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
                    key.mods = Self.ghosttyMods(event.mods)
                    key.consumed_mods = GHOSTTY_MODS_NONE
                    key.keycode = event.keyCode
                    key.text = text
                    key.unshifted_codepoint = event.unshiftedCodepoint
                    key.composing = false
                    _ = ghostty_surface_key(surface, key)
                }
            case .text(let text):
                Self.withBytes(text) { ghostty_surface_text_input(surface, $0, $1) }
            case .paste(let text):
                Self.withBytes(text) { ghostty_surface_text(surface, $0, $1) }
            case .preedit(let text):
                Self.withBytes(text) { ghostty_surface_preedit(surface, $0, $1) }
                requestRedraw()
            }
        }
    }

    static func ghosttyMods(_ mods: TerminalKeyMods) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if mods.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if mods.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if mods.contains(.alternate) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if mods.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private static func withCString(_ text: String?, _ body: (UnsafePointer<CChar>?) -> Void) {
        guard let text, !text.isEmpty else { return body(nil) }
        text.withCString { body($0) }
    }

    private static func withBytes(_ text: String, _ body: (UnsafePointer<CChar>, UInt) -> Void) {
        let utf8 = Array(text.utf8CString)
        utf8.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            body(base, UInt(buffer.count - 1))
        }
    }

    /// The cursor cell in this view's points (the IME candidate window and
    /// the keyboard pan use it).
    var cursorRect: CGRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        // x is the cell's midpoint and y its bottom (Ghostty's IME point).
        return CGRect(x: x - width / 2, y: y - height, width: max(width, 1), height: height)
    }
}

/// Modifier flags UIKit reports, as the router's modifiers.
extension TerminalKeyMods {
    init(_ flags: UIKeyModifierFlags) {
        var mods: TerminalKeyMods = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.alternate) { mods.insert(.alternate) }
        if flags.contains(.command) { mods.insert(.command) }
        self = mods
    }
}
