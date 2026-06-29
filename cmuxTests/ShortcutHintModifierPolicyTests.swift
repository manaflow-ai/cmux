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
    func titlebarPolicyMatchesHeldModifierToShortcutModifier() {
        let commandShortcut = StoredShortcut(key: "R", command: true, shift: false, option: false, control: false)
        let controlShortcut = StoredShortcut(key: "R", command: false, shift: false, option: false, control: true)

        #expect(ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: commandShortcut,
            alwaysShowShortcutHints: false,
            modifierFlags: [.command],
            modifierHoldHintsEnabled: true
        ))
        #expect(!ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: commandShortcut,
            alwaysShowShortcutHints: false,
            modifierFlags: [.control],
            modifierHoldHintsEnabled: true
        ))
        #expect(ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: controlShortcut,
            alwaysShowShortcutHints: false,
            modifierFlags: [.control],
            modifierHoldHintsEnabled: true
        ))
        #expect(!ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: controlShortcut,
            alwaysShowShortcutHints: false,
            modifierFlags: [.command],
            modifierHoldHintsEnabled: true
        ))
    }

    @Test
    func titlebarModeModifierGateSuppressesCommandOnlyWhenCommandHintsAreDisabled() {
        #expect(!ShortcutHintTitlebarPolicy.modifierHoldHintsEnabled(
            showModifierHoldHints: true,
            showCommandHoldHints: false,
            heldModifierFlags: [.command]
        ))
        #expect(ShortcutHintTitlebarPolicy.modifierHoldHintsEnabled(
            showModifierHoldHints: true,
            showCommandHoldHints: false,
            heldModifierFlags: [.control]
        ))
        #expect(!ShortcutHintTitlebarPolicy.modifierHoldHintsEnabled(
            showModifierHoldHints: false,
            showCommandHoldHints: true,
            heldModifierFlags: [.control]
        ))
    }

    @Test
    func modifierHoldHintsSettingSuppressesCommandAndControlHintActivation() throws {
        try withDefaultsSuite { defaults in
            defaults.set(false, forKey: ShortcutHintDebugSettings.showModifierHoldHintsKey)
            let policy = ShortcutHintModifierPolicy(defaults: defaults)

            #expect(!ShortcutHintDebugSettings(defaults: defaults).modifierHoldHintsEnabled)
            #expect(!policy.shouldShowHints(for: [.command]))
            #expect(!policy.shouldShowHints(for: [.control]))
            #expect(!policy.shouldShowCommandHints(for: [.command]))
            #expect(!policy.shouldShowControlHints(for: [.control]))
        }
    }

    @Test
    func commandHoldHintsSettingSuppressesCommandOnly() throws {
        try withDefaultsSuite { defaults in
            defaults.set(false, forKey: ShortcutHintDebugSettings.showCommandHoldHintsKey)
            let settings = ShortcutHintDebugSettings(defaults: defaults)
            let policy = ShortcutHintModifierPolicy(defaults: defaults)

            #expect(settings.modifierHoldHintsEnabled)
            #expect(!settings.commandHoldHintsEnabled)
            #expect(!policy.shouldShowHints(for: [.command]))
            #expect(policy.shouldShowHints(for: [.control]))
            #expect(!policy.shouldShowCommandHints(for: [.command]))
            #expect(policy.shouldShowControlHints(for: [.control]))
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
