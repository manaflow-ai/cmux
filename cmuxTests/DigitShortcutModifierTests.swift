import XCTest
import AppKit
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - DigitShortcutModifierSettings Tests

final class DigitShortcutModifierSettingsTests: XCTestCase {

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "DigitShortcutModifierSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        body(defaults)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Defaults

    func testWorkspaceFlagsDefaultToCommand() {
        withDefaults { defaults in
            let flags = DigitShortcutModifierSettings.workspaceFlags(defaults: defaults)
            XCTAssertEqual(flags, [.command])
        }
    }

    func testSurfaceFlagsDefaultToControl() {
        withDefaults { defaults in
            let flags = DigitShortcutModifierSettings.surfaceFlags(defaults: defaults)
            XCTAssertEqual(flags, [.control])
        }
    }

    // MARK: Custom single modifier

    func testWorkspaceFlagsReadsStoredOption() {
        withDefaults { defaults in
            defaults.set(Int(NSEvent.ModifierFlags.option.rawValue), forKey: DigitShortcutModifierSettings.workspaceModifierKey)
            let flags = DigitShortcutModifierSettings.workspaceFlags(defaults: defaults)
            XCTAssertEqual(flags, [.option])
        }
    }

    func testSurfaceFlagsReadsStoredCommand() {
        withDefaults { defaults in
            defaults.set(Int(NSEvent.ModifierFlags.command.rawValue), forKey: DigitShortcutModifierSettings.surfaceModifierKey)
            let flags = DigitShortcutModifierSettings.surfaceFlags(defaults: defaults)
            XCTAssertEqual(flags, [.command])
        }
    }

    // MARK: Combo modifiers

    func testWorkspaceFlagsReadsComboModifier() {
        withDefaults { defaults in
            let combo: NSEvent.ModifierFlags = [.command, .shift]
            defaults.set(Int(combo.rawValue), forKey: DigitShortcutModifierSettings.workspaceModifierKey)
            let flags = DigitShortcutModifierSettings.workspaceFlags(defaults: defaults)
            XCTAssertTrue(flags.contains(.command))
            XCTAssertTrue(flags.contains(.shift))
            XCTAssertFalse(flags.contains(.option))
            XCTAssertFalse(flags.contains(.control))
        }
    }

    func testSurfaceFlagsReadsTripleCombo() {
        withDefaults { defaults in
            let combo: NSEvent.ModifierFlags = [.control, .option, .shift]
            defaults.set(Int(combo.rawValue), forKey: DigitShortcutModifierSettings.surfaceModifierKey)
            let flags = DigitShortcutModifierSettings.surfaceFlags(defaults: defaults)
            XCTAssertTrue(flags.contains(.control))
            XCTAssertTrue(flags.contains(.option))
            XCTAssertTrue(flags.contains(.shift))
            XCTAssertFalse(flags.contains(.command))
        }
    }

    // MARK: Zero stored value falls back to default

    func testZeroStoredValueFallsBackToDefault() {
        withDefaults { defaults in
            defaults.set(0, forKey: DigitShortcutModifierSettings.workspaceModifierKey)
            let flags = DigitShortcutModifierSettings.workspaceFlags(defaults: defaults)
            XCTAssertEqual(flags, [.command], "Zero should fall back to default workspace modifier")
        }
    }

    // MARK: Symbol strings

    func testSymbolStringCommand() {
        XCTAssertEqual(DigitShortcutModifierSettings.symbolString(for: [.command]), "⌘")
    }

    func testSymbolStringControl() {
        XCTAssertEqual(DigitShortcutModifierSettings.symbolString(for: [.control]), "⌃")
    }

    func testSymbolStringOption() {
        XCTAssertEqual(DigitShortcutModifierSettings.symbolString(for: [.option]), "⌥")
    }

    func testSymbolStringShift() {
        XCTAssertEqual(DigitShortcutModifierSettings.symbolString(for: [.shift]), "⇧")
    }

    func testSymbolStringComboOrdering() {
        // Symbols should follow standard macOS ordering: ⌃⌥⇧⌘
        let combo: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        XCTAssertEqual(DigitShortcutModifierSettings.symbolString(for: combo), "⌃⌥⇧⌘")
    }

    func testSymbolStringCommandShift() {
        let combo: NSEvent.ModifierFlags = [.command, .shift]
        XCTAssertEqual(DigitShortcutModifierSettings.symbolString(for: combo), "⇧⌘")
    }

    // MARK: Display name

    func testDisplayNameSingleModifier() {
        XCTAssertEqual(DigitShortcutModifierSettings.displayName(for: [.command]), "Command")
    }

    func testDisplayNameCombo() {
        let combo: NSEvent.ModifierFlags = [.command, .shift]
        XCTAssertEqual(DigitShortcutModifierSettings.displayName(for: combo), "Shift+Command")
    }

    // MARK: EventModifiers conversion

    func testEventModifiersFromStoredCommand() {
        let stored = Int(NSEvent.ModifierFlags.command.rawValue)
        let modifiers = DigitShortcutModifierSettings.eventModifiers(
            for: stored, fallback: DigitShortcutModifierSettings.defaultWorkspaceFlags
        )
        XCTAssertTrue(modifiers.contains(.command))
        XCTAssertFalse(modifiers.contains(.shift))
    }

    func testEventModifiersFromStoredCombo() {
        let combo: NSEvent.ModifierFlags = [.command, .shift]
        let stored = Int(combo.rawValue)
        let modifiers = DigitShortcutModifierSettings.eventModifiers(
            for: stored, fallback: DigitShortcutModifierSettings.defaultWorkspaceFlags
        )
        XCTAssertTrue(modifiers.contains(.command))
        XCTAssertTrue(modifiers.contains(.shift))
    }

    func testEventModifiersZeroFallsBackToDefault() {
        let modifiers = DigitShortcutModifierSettings.eventModifiers(
            for: 0, fallback: [.control]
        )
        XCTAssertTrue(modifiers.contains(.control))
        XCTAssertFalse(modifiers.contains(.command))
    }
}

// MARK: - Configurable Hint Modifier Tests

final class ConfigurableHintModifierTests: XCTestCase {

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "ConfigurableHintModifierTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        body(defaults)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Default modifiers

    func testDefaultCommandTriggersHints() {
        withDefaults { defaults in
            defaults.set(true, forKey: ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: [.command], defaults: defaults))
        }
    }

    func testDefaultControlTriggersHints() {
        withDefaults { defaults in
            defaults.set(true, forKey: ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: [.control], defaults: defaults))
        }
    }

    func testDefaultOptionDoesNotTriggerHints() {
        withDefaults { defaults in
            defaults.set(true, forKey: ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.option], defaults: defaults))
        }
    }

    func testEmptyFlagsDoNotTriggerHints() {
        withDefaults { defaults in
            defaults.set(true, forKey: ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [], defaults: defaults))
        }
    }

    // MARK: Custom modifiers

    func testCustomWorkspaceModifierTriggersHints() {
        withDefaults { defaults in
            defaults.set(true, forKey: ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
            let combo: NSEvent.ModifierFlags = [.option, .shift]
            defaults.set(Int(combo.rawValue), forKey: DigitShortcutModifierSettings.workspaceModifierKey)
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: combo, defaults: defaults))
        }
    }

    func testOldDefaultCommandDoesNotTriggerAfterCustomWorkspace() {
        withDefaults { defaults in
            defaults.set(true, forKey: ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
            let combo: NSEvent.ModifierFlags = [.option, .shift]
            defaults.set(Int(combo.rawValue), forKey: DigitShortcutModifierSettings.workspaceModifierKey)
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.command], defaults: defaults))
        }
    }

    func testCustomSurfaceModifierTriggersHints() {
        withDefaults { defaults in
            defaults.set(true, forKey: ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
            defaults.set(Int(NSEvent.ModifierFlags.option.rawValue), forKey: DigitShortcutModifierSettings.surfaceModifierKey)
            XCTAssertTrue(ShortcutHintModifierPolicy.shouldShowHints(for: [.option], defaults: defaults))
        }
    }

    func testOldDefaultControlDoesNotTriggerAfterCustomSurface() {
        withDefaults { defaults in
            defaults.set(true, forKey: ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
            defaults.set(Int(NSEvent.ModifierFlags.option.rawValue), forKey: DigitShortcutModifierSettings.surfaceModifierKey)
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.control], defaults: defaults))
        }
    }

    // MARK: Hints disabled

    func testHintsDisabledReturnsFalseEvenForMatchingModifier() {
        withDefaults { defaults in
            defaults.set(false, forKey: ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.command], defaults: defaults))
        }
    }

    // MARK: Partial match does not trigger

    func testPartialComboDoesNotTrigger() {
        withDefaults { defaults in
            defaults.set(true, forKey: ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
            let combo: NSEvent.ModifierFlags = [.command, .shift]
            defaults.set(Int(combo.rawValue), forKey: DigitShortcutModifierSettings.workspaceModifierKey)
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.command], defaults: defaults))
        }
    }

    func testSupersetDoesNotTrigger() {
        withDefaults { defaults in
            defaults.set(true, forKey: ShortcutHintDebugSettings.showHintsOnCommandHoldKey)
            XCTAssertFalse(ShortcutHintModifierPolicy.shouldShowHints(for: [.command, .shift, .option], defaults: defaults))
        }
    }
}
