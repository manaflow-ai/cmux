import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct GhosttyHostKeybindDefaultsTests {
    @Test
    func defaultHostBindingsStayUnboundAfterCmuxShortcutsAreCleared() throws {
        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        GhosttyApp.shared.loadGhosttyHostKeybindDefaults(config)
        GhosttyApp.shared.loadCmuxOwnedGhosttyKeybindOverrides(config)
        ghostty_config_finalize(config)
        #expect(ghostty_config_diagnostics_count(config) == 0)
        let command = GHOSTTY_MODS_SUPER.rawValue
        let shift = GHOSTTY_MODS_SHIFT.rawValue
        let control = GHOSTTY_MODS_CTRL.rawValue
        let defaults: [(String, UInt32, UInt32)] = [
            ("n", 45, command), ("t", 17, command), ("q", 12, command),
            (",", 43, command), ("\r", 36, command), ("p", 35, command | shift),
            ("[", 33, command | shift), ("]", 30, command | shift),
            ("\t", 48, control), ("\t", 48, control | shift)
        ]
        for (text, keyCode, modifiers) in defaults {
            #expect(!isBinding(config, text: text, keyCode: keyCode, modifiers: modifiers))
        }
        let digitKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for digit in 1...9 {
            #expect(!isBinding(config, text: String(digit), keyCode: digitKeyCodes[digit - 1], modifiers: command))
            // An empty Unicode value still must not match the physical digit fallback.
            #expect(!isBinding(config, text: "", keyCode: digitKeyCodes[digit - 1], modifiers: command))
        }
    }

    @Test
    func explicitUserBindingsLoadAfterDefaultsButBeforeCmuxOwnedUnbinds() throws {
        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        GhosttyApp.shared.loadGhosttyHostKeybindDefaults(config)
        let contents = """
            keybind = super+n=new_tab
            keybind = ctrl+b>1=goto_tab:1
            keybind = super+1=goto_tab:1
            keybind = super+digit_1=goto_tab:1
            """
        contents.withCString { pointer in
            ghostty_config_load_string(config, pointer, UInt(contents.utf8.count), "/__cmux_test__/host-defaults.conf")
        }
        GhosttyApp.shared.loadCmuxOwnedGhosttyKeybindOverrides(config)
        ghostty_config_finalize(config)
        #expect(ghostty_config_diagnostics_count(config) == 0)
        #expect(isBinding(config, text: "n", keyCode: 45, modifiers: GHOSTTY_MODS_SUPER.rawValue))
        #expect(isBinding(config, text: "b", keyCode: 11, modifiers: GHOSTTY_MODS_CTRL.rawValue))
        #expect(!isBinding(config, text: "1", keyCode: 18, modifiers: GHOSTTY_MODS_SUPER.rawValue))
        #expect(!isBinding(config, text: "", keyCode: 18, modifiers: GHOSTTY_MODS_SUPER.rawValue))
    }

    private func isBinding(
        _ config: ghostty_config_t, text: String, keyCode: UInt32, modifiers: UInt32
    ) -> Bool {
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = keyCode
        key.mods = ghostty_input_mods_e(rawValue: modifiers)
        key.unshifted_codepoint = text.unicodeScalars.first?.value ?? 0
        return text.withCString { pointer in
            key.text = pointer
            return ghostty_config_key_is_binding(config, key)
        }
    }
}
