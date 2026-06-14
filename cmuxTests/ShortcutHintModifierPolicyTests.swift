import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Shortcut hint modifier policy")
struct ShortcutHintModifierPolicyTests {
    @Test
    func titlebarShortcutHintActionSlotsIncludeFocusHistoryNavigation() {
        #expect(
            TitlebarShortcutHintActionSlot.allCases.map(\.action) == [
                .toggleSidebar,
                .showNotifications,
                .newTab,
                .focusHistoryBack,
                .focusHistoryForward,
            ]
        )
    }

    @Test
    func titlebarShortcutHintAlwaysShowAllowsBoundNonCommandShortcut() {
        let controlShortcut = StoredShortcut(key: "R", command: false, shift: false, option: false, control: true)
        let commandShortcut = StoredShortcut(key: "R", command: true, shift: false, option: false, control: false)

        #expect(ShortcutHintTitlebarPolicy.shouldShow(shortcut: controlShortcut, alwaysShowShortcutHints: true, modifierPressed: false))
        #expect(!ShortcutHintTitlebarPolicy.shouldShow(shortcut: controlShortcut, alwaysShowShortcutHints: false, modifierPressed: true))
        #expect(ShortcutHintTitlebarPolicy.shouldShow(shortcut: commandShortcut, alwaysShowShortcutHints: false, modifierPressed: true))
        #expect(!ShortcutHintTitlebarPolicy.shouldShow(shortcut: commandShortcut, alwaysShowShortcutHints: false, modifierPressed: true, modifierHoldHintsEnabled: false))
        #expect(ShortcutHintTitlebarPolicy.shouldShow(shortcut: controlShortcut, alwaysShowShortcutHints: true, modifierPressed: false, modifierHoldHintsEnabled: false))
        #expect(!ShortcutHintTitlebarPolicy.shouldShow(shortcut: .unbound, alwaysShowShortcutHints: true, modifierPressed: true))
    }

    @Test
    func shortcutHintRequiresEnabledCommandOrControlOnlyModifier() throws {
        try withDefaultsSuite { defaults in
            #expect(ShortcutHintModifierPolicy.shouldShowHints(for: [.command], defaults: defaults))
            #expect(ShortcutHintModifierPolicy.shouldShowHints(for: [.control], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowHints(for: [], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowHints(for: [.command, .shift], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowHints(for: [.control, .shift], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowHints(for: [.command, .option], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowHints(for: [.control, .option], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowHints(for: [.command, .control], defaults: defaults))
        }
    }

    @Test
    func shortcutHintShowsForControlModifier() throws {
        try withDefaultsSuite { defaults in
            #expect(ShortcutHintModifierPolicy.shouldShowHints(for: [.control], defaults: defaults))
        }
    }

    @Test
    func controlOnlyShortcutHintRequiresControlModifier() throws {
        try withDefaultsSuite { defaults in
            #expect(ShortcutHintModifierPolicy.shouldShowControlHints(for: [.control], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowControlHints(for: [.command], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowControlHints(for: [.control, .shift], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowControlHints(for: [.control, .option], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowControlHints(for: [], defaults: defaults))
        }
    }

    @Test
    func commandOnlyShortcutHintRequiresCommandModifier() throws {
        try withDefaultsSuite { defaults in
            #expect(ShortcutHintModifierPolicy.shouldShowCommandHints(for: [.command], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowCommandHints(for: [.control], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowCommandHints(for: [.command, .shift], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowCommandHints(for: [.command, .option], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowCommandHints(for: [], defaults: defaults))
        }
    }

    @Test
    func commandAndControlHintsDefaultToEnabled() throws {
        try withDefaultsSuite { defaults in
            #expect(ShortcutHintModifierPolicy.shouldShowHints(for: [.command], defaults: defaults))
            #expect(ShortcutHintModifierPolicy.shouldShowHints(for: [.control], defaults: defaults))
        }
    }

    @Test
    func modifierHoldHintsSettingSuppressesCommandAndControlHints() throws {
        try withDefaultsSuite { defaults in
            defaults.set(false, forKey: ShortcutHintDebugSettings.showModifierHoldHintsKey)

            #expect(!ShortcutHintDebugSettings.modifierHoldHintsEnabled(defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowHints(for: [.command], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowHints(for: [.control], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowCommandHints(for: [.command], defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowControlHints(for: [.control], defaults: defaults))
        }
    }

    @Test
    func shortcutHintIgnoresCustomizedWorkspaceShortcutModifiers() throws {
        let action = KeyboardShortcutSettings.Action.selectWorkspaceByNumber
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer { KeyboardShortcutSettings.setShortcut(originalShortcut, for: action) }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "1", command: false, shift: false, option: false, control: true),
            for: action
        )

        try withDefaultsSuite { defaults in
            #expect(ShortcutHintModifierPolicy.shouldShowHints(for: [.command], defaults: defaults))
            #expect(ShortcutHintModifierPolicy.shouldShowHints(for: [.control], defaults: defaults))
        }
    }

    @Test
    func shortcutHintIgnoresWorkspaceShortcutChords() throws {
        let action = KeyboardShortcutSettings.Action.selectWorkspaceByNumber
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer { KeyboardShortcutSettings.setShortcut(originalShortcut, for: action) }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "1",
                command: false,
                shift: false,
                option: false,
                control: true,
                chordKey: "2",
                chordCommand: true,
                chordShift: false,
                chordOption: false,
                chordControl: false
            ),
            for: action
        )

        try withDefaultsSuite { defaults in
            #expect(ShortcutHintModifierPolicy.shouldShowHints(for: [.command], defaults: defaults))
            #expect(ShortcutHintModifierPolicy.shouldShowHints(for: [.control], defaults: defaults))
        }
    }

    @Test
    func shortcutHintUsesIntentionalHoldDelay() {
        #expect(abs(ShortcutHintModifierPolicy.intentionalHoldDelay - 0.30) <= 0.001)
    }

    @Test
    func currentWindowRequiresHostWindowToBeKeyAndMatchEventWindow() {
        #expect(ShortcutHintModifierPolicy.isCurrentWindow(hostWindowNumber: 42, hostWindowIsKey: true, eventWindowNumber: 42, keyWindowNumber: 42))
        #expect(!ShortcutHintModifierPolicy.isCurrentWindow(hostWindowNumber: 42, hostWindowIsKey: true, eventWindowNumber: 7, keyWindowNumber: 42))
        #expect(!ShortcutHintModifierPolicy.isCurrentWindow(hostWindowNumber: 42, hostWindowIsKey: false, eventWindowNumber: 42, keyWindowNumber: 42))
    }

    @Test
    func windowScopedShortcutHintsUseKeyWindowWhenNoEventWindowIsAvailable() throws {
        try withDefaultsSuite { defaults in
            #expect(ShortcutHintModifierPolicy.shouldShowHints(for: [.command], hostWindowNumber: 42, hostWindowIsKey: true, eventWindowNumber: nil, keyWindowNumber: 42, defaults: defaults))
            #expect(!ShortcutHintModifierPolicy.shouldShowHints(for: [.command], hostWindowNumber: 42, hostWindowIsKey: true, eventWindowNumber: nil, keyWindowNumber: 7, defaults: defaults))
            #expect(ShortcutHintModifierPolicy.shouldShowHints(for: [.control], hostWindowNumber: 42, hostWindowIsKey: true, eventWindowNumber: nil, keyWindowNumber: 42, defaults: defaults))
        }
    }

    private func withDefaultsSuite(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "ShortcutHintModifierPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
