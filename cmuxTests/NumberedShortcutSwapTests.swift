import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Numbered shortcut swap", .serialized)
struct NumberedShortcutSwapTests {
    @Test func workspaceAndSurfaceNumberedDefaultsUseSeparateModifierLanes() {
        #expect(
            KeyboardShortcutSettings.Action.selectWorkspaceByNumber.defaultShortcut ==
                StoredShortcut(key: "1", command: false, shift: false, option: false, control: true)
        )
        #expect(
            KeyboardShortcutSettings.Action.selectSurfaceByNumber.defaultShortcut ==
                StoredShortcut(key: "1", command: true, shift: false, option: false, control: false)
        )
    }

    @MainActor
    @Test func workspaceAndSurfaceShortcutsCanSwapModifierFamilies() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-numbered-shortcut-swap"
        )
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        }
        KeyboardShortcutSettings.resetAll()

        let workspaceDefault = KeyboardShortcutSettings.Action.selectWorkspaceByNumber.defaultShortcut
        let surfaceDefault = KeyboardShortcutSettings.Action.selectSurfaceByNumber.defaultShortcut

        let presentation = try #require(ShortcutRecorderValidationPresentation(
            attempt: ShortcutRecorderRejectedAttempt(
                reason: .conflictsWithAction(.selectSurfaceByNumber),
                proposedShortcut: surfaceDefault
            ),
            action: .selectWorkspaceByNumber,
            currentShortcut: workspaceDefault
        ))

        #expect(presentation.message == "This shortcut conflicts with Select Surface 1…9 (⌘1…9). Swap shortcuts?")
        #expect(presentation.swapButtonTitle == "Swap")
        #expect(presentation.canSwap)
        #expect(presentation.undoButtonTitle == "Undo")

        #expect(
            KeyboardShortcutSettings.swapShortcutConflict(
                proposedShortcut: surfaceDefault,
                currentAction: .selectWorkspaceByNumber,
                conflictingAction: .selectSurfaceByNumber,
                previousShortcut: workspaceDefault
            )
        )
        #expect(KeyboardShortcutSettings.shortcut(for: .selectWorkspaceByNumber) == surfaceDefault)
        #expect(KeyboardShortcutSettings.shortcut(for: .selectSurfaceByNumber) == workspaceDefault)
    }
}
