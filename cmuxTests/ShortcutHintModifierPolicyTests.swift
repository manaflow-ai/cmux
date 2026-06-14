import AppKit
import CmuxFoundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Shortcut hint modifier-hold policy", .serialized)
struct ShortcutHintModifierHoldPolicyTests {
    @Test
    func titlebarPolicySuppressesCommandHoldHintsWhenModifierHoldHintsAreDisabled() {
        let commandShortcut = StoredShortcut(key: "R", command: true, shift: false, option: false, control: false)
        let controlShortcut = StoredShortcut(key: "R", command: false, shift: false, option: false, control: true)

        #expect(!ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: commandShortcut,
            alwaysShowShortcutHints: false,
            modifierPressed: true,
            modifierHoldHintsEnabled: false
        ))
        #expect(ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: controlShortcut,
            alwaysShowShortcutHints: true,
            modifierPressed: false,
            modifierHoldHintsEnabled: false
        ))
    }

    @Test
    func modifierHoldHintsSettingSuppressesCommandAndControlHintActivation() throws {
        try withDefaultsSuite { defaults in
            defaults.set(false, forKey: ShortcutHintDebugSettings.showModifierHoldHintsKey)

            #expect(!ShortcutHintDebugSettings.modifierHoldHintsEnabled(defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowHints(for: [.command], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowHints(for: [.control], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowCommandHints(for: [.command], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowControlHints(for: [.control], defaults: defaults))
        }
    }

    private func withDefaultsSuite(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "ShortcutHintModifierHoldPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
