import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Snippets tool is an ordinary right-sidebar mode: always available,
/// hideable through the tab preferences, with its own switch action.
@MainActor
struct SnippetsSidebarModeTests {
    private func makeDefaults() -> UserDefaults {
        let name = "SnippetsSidebarModeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func modeIdentity() {
        #expect(RightSidebarMode.snippets.rawValue == "snippets")
        #expect(RightSidebarMode.snippets.symbolName == "text.badge.plus")
        #expect(RightSidebarMode.snippets.shortcutAction == .switchRightSidebarToSnippets)
        #expect(!RightSidebarMode.snippets.canOpenAsPane)
        #expect(RightSidebarMode.snippets.label == "Snippets")
        #expect(RightSidebarMode.from(cliArgument: "snippets") == .snippets)
        #expect(KeyboardShortcutSettings.Action.switchRightSidebarToSnippets.label == "Show Sidebar Snippets")
    }

    @Test func alwaysAvailableAndListedAfterCloud() throws {
        #expect(RightSidebarMode.snippets.isAvailable(feedEnabled: false, machinesEnabled: false, devicesEnabled: false))
        let modes = RightSidebarMode.availableModes(feedEnabled: true, machinesEnabled: true)
        let cloud = try #require(modes.firstIndex(of: .machines))
        #expect(modes.firstIndex(of: .snippets) == cloud + 1)
    }

    @Test func hiddenTabDropsOutOfPositionalDigits() {
        let defaults = makeDefaults()
        #expect(RightSidebarMode.visibleModes(defaults: defaults).contains(.snippets))
        _ = RightSidebarTabPreferences.setHidden(true, mode: .snippets, defaults: defaults)
        #expect(!RightSidebarMode.visibleModes(defaults: defaults).contains(.snippets))
        #expect(RightSidebarMode.positionalDigit(for: .snippets, defaults: defaults) == nil)
    }

    @Test func switchActionIsPrivateAndRoutedLikeTheOtherModeSwitches() {
        let action = KeyboardShortcutSettings.Action.switchRightSidebarToSnippets
        #expect(!action.isPublicShortcutAction)
        #expect(action.hasPriorityShortcutRouting == KeyboardShortcutSettings.Action.switchRightSidebarToMachines.hasPriorityShortcutRouting)
        #expect(action.shortcutContext == KeyboardShortcutSettings.Action.switchRightSidebarToMachines.shortcutContext)
    }

    @Test func commandPaletteCommandResolvesToTheSwitchAction() {
        let commandID = ContentView.commandPaletteRightSidebarModeCommandID(.snippets)
        #expect(commandID == "palette.showRightSidebarSnippets")
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: commandID) == .switchRightSidebarToSnippets)
    }

    @Test func searchFieldLookupIsCachedPerWindowAndDropsAFieldThatLeft() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = root
        let host = SnippetsKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        let field = SidebarSearchField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        field.setAccessibilityIdentifier(SnippetsSidebarFocusBridge.searchFieldIdentifier)
        root.addSubview(host)
        root.addSubview(field)

        #expect(SnippetsSidebarFocusBridge.searchField(for: host) === field)
        #expect(host.cachedSearchField === field)
        #expect(SnippetsSidebarFocusBridge.responderIsSearchField(field, for: host))
        #expect(!SnippetsSidebarFocusBridge.responderIsSearchField(host, for: host))

        field.removeFromSuperview()
        #expect(SnippetsSidebarFocusBridge.searchField(for: host) == nil, "a field that left the window is not reused")
    }
}
