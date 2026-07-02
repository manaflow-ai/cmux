import CmuxFoundation
import CmuxSettings
import Testing

/// Guards the hardcoded `UserDefaults` key and default in
/// ``ShortcutHintDebugSettings`` against the canonical shortcut-hint catalog
/// entries. `CmuxFoundation` is a leaf module and cannot import
/// `CmuxSettings`, so the values are duplicated; this suite fails if they drift.
@Suite("Shortcut hint debug settings binding")
struct ShortcutHintDebugSettingsBindingTests {
    @Test
    func modifierHoldKeyAndDefaultMatchSettingCatalog() {
        let catalogEntry = SettingCatalog().shortcuts.showModifierHoldHints

        #expect(ShortcutHintDebugSettings.showModifierHoldHintsKey == catalogEntry.userDefaultsKey)
        #expect(ShortcutHintDebugSettings.defaultShowModifierHoldHints == catalogEntry.defaultValue)
    }

    @Test
    func commandHoldKeyAndDefaultMatchSettingCatalog() {
        let catalogEntry = SettingCatalog().shortcuts.showCommandHoldHints

        #expect(ShortcutHintDebugSettings.showCommandHoldHintsKey == catalogEntry.userDefaultsKey)
        #expect(ShortcutHintDebugSettings.defaultShowCommandHoldHints == catalogEntry.defaultValue)
    }
}
