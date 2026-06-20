import Carbon
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SystemWideHotkeyShortcutPolicyTests {
    @Test func showHideAllWindowsAcceptsCommandGravePhysicalHotkeys() {
        let shortcut = commandGraveShortcut()

        #expect(
            shortcut.carbonHotKeyRegistration ==
                CarbonHotKeyRegistration(keyCode: 50, modifiers: UInt32(cmdKey))
        )
        #expect(
            KeyboardShortcutSettings.Action.showHideAllWindows.normalizedRecordedShortcutResult(shortcut) ==
                .accepted(shortcut)
        )

        let shiftedShortcut = commandGraveShortcut(shift: true)

        #expect(
            shiftedShortcut.carbonHotKeyRegistration ==
                CarbonHotKeyRegistration(keyCode: 50, modifiers: UInt32(cmdKey | shiftKey))
        )
        #expect(
            KeyboardShortcutSettings.Action.showHideAllWindows.normalizedRecordedShortcutResult(shiftedShortcut) ==
                .accepted(shiftedShortcut)
        )
    }

    @Test func globalSearchStillRejectsCommandGraveWindowCyclingHotkey() {
        let shortcut = commandGraveShortcut()

        #expect(
            KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(shortcut) ==
                .rejected(.reservedBySystem)
        )
    }

    private func commandGraveShortcut(shift: Bool = false) -> StoredShortcut {
        StoredShortcut(
            key: "`",
            command: true,
            shift: shift,
            option: false,
            control: false,
            keyCode: 50
        )
    }
}
