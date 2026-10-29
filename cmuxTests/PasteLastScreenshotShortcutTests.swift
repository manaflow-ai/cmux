import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Paste Last Screenshot: a rebindable shortcut with no default binding, the
/// command palette row that shares its action, and the Dock route.
@MainActor
@Suite("Paste Last Screenshot shortcut")
struct PasteLastScreenshotShortcutTests {
    private let action = KeyboardShortcutSettings.Action.pasteLastScreenshot

    @Test("is in the catalog, visible in Settings, and unbound by default")
    func catalogEntryIsVisibleAndUnbound() {
        #expect(action.rawValue == "pasteLastScreenshot")
        #expect(action.label == "Paste Last Screenshot")
        #expect(action.defaultsKey == "shortcut.pasteLastScreenshot")
        #expect(action.defaultShortcut.isUnbound)
        #expect(KeyboardShortcutSettings.publicShortcutActions.contains(action))
        #expect(KeyboardShortcutSettings.settingsVisibleActions.contains(action))
    }

    @Test("the settings package action matches the app action")
    func settingsPackageActionStaysAligned() throws {
        let settingsAction = try #require(ShortcutAction(rawValue: action.rawValue))
        #expect(settingsAction.defaultShortcut == nil)
        #expect(settingsAction.displayName == action.label)
        #expect(settingsAction.group == ShortcutAction.sendCtrlFToTerminal.group)
        #expect(settingsAction.defaultFocusWhenClause == ShortcutAction.sendCtrlFToTerminal.defaultFocusWhenClause)
        #expect(ShortcutAction.settingsVisibleActions.contains(settingsAction))
    }

    @Test("targets the focused terminal, including one in the Dock")
    func targetsFocusedTerminal() {
        #expect(action.shortcutContext == KeyboardShortcutSettings.Action.sendCtrlFToTerminal.shortcutContext)
        #expect(action.dockShortcutRoutingDisposition == .dockScoped)
    }

    @Test("the command palette row shows the configured shortcut")
    func paletteCommandMapsToShortcut() {
        #expect(
            ContentView.commandPaletteShortcutAction(forCommandID: "palette.terminalPasteLastScreenshot")
                == .pasteLastScreenshot
        )
    }
}
