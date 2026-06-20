import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
private typealias AppStoredShortcut = cmux_DEV.StoredShortcut
#elseif canImport(cmux)
@testable import cmux
private typealias AppStoredShortcut = cmux.StoredShortcut
#endif

@Suite struct OpenChatShortcutSettingsTests {
    @Test func defaultsToCmdCtrlShiftCAndIsUserEditable() {
        let cmdCtrlShiftC = AppStoredShortcut(key: "c", command: true, shift: true, option: false, control: true)

        #expect(KeyboardShortcutSettings.shortcut(for: .openChat) == cmdCtrlShiftC)
        #expect(
            KeyboardShortcutSettings.Action.openChat.normalizedRecordedShortcutResult(cmdCtrlShiftC) == .accepted(cmdCtrlShiftC),
            "Default Open Chat shortcut must not conflict with any other action"
        )
        #expect(
            KeyboardShortcutSettings.settingsVisibleActions.contains(.openChat),
            "Open Chat must be visible/editable in Settings > Keyboard Shortcuts"
        )
    }
}
