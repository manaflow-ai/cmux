import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Workspace number shortcut menu routing", .serialized)
struct WorkspaceNumberShortcutMenuRoutingTests {
    @MainActor
    @Test func workspaceNumberShortcutIsDispatcherOwnedInsteadOfStaticMenuEquivalent() {
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-workspace-number-shortcut"
        )
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        }
        KeyboardShortcutSettings.resetAll()

        let dispatcherShortcut = KeyboardShortcutSettings.shortcut(for: .selectWorkspaceByNumber)
        #expect(dispatcherShortcut == KeyboardShortcutSettings.Action.selectWorkspaceByNumber.defaultShortcut)
        #expect(KeyboardShortcutSettings.menuShortcut(for: .selectWorkspaceByNumber).isUnbound)
    }
}
