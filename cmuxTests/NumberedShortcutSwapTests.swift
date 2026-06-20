import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Numbered shortcut swap", .serialized)
struct NumberedShortcutSwapTests {
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

        let workspaceDigits = StoredShortcut(key: "1", command: true, shift: false, option: false, control: false)
        let surfaceDigits = StoredShortcut(key: "1", command: false, shift: false, option: false, control: true)
        KeyboardShortcutSettings.setShortcut(workspaceDigits, for: .selectWorkspaceByNumber)
        KeyboardShortcutSettings.setShortcut(surfaceDigits, for: .selectSurfaceByNumber)

        let presentation = try #require(ShortcutRecorderValidationPresentation(
            attempt: ShortcutRecorderRejectedAttempt(
                reason: .conflictsWithAction(.selectSurfaceByNumber),
                proposedShortcut: surfaceDigits
            ),
            action: .selectWorkspaceByNumber,
            currentShortcut: workspaceDigits
        ))

        #expect(presentation.message == "This shortcut conflicts with Select Surface 1…9 (⌃1…9). Swap shortcuts?")
        #expect(presentation.swapButtonTitle == "Swap")
        #expect(presentation.canSwap)
        #expect(presentation.undoButtonTitle == "Undo")

        #expect(
            KeyboardShortcutSettings.swapShortcutConflict(
                proposedShortcut: surfaceDigits,
                currentAction: .selectWorkspaceByNumber,
                conflictingAction: .selectSurfaceByNumber,
                previousShortcut: workspaceDigits
            )
        )
        #expect(KeyboardShortcutSettings.shortcut(for: .selectWorkspaceByNumber) == surfaceDigits)
        #expect(KeyboardShortcutSettings.shortcut(for: .selectSurfaceByNumber) == workspaceDigits)
    }
}
