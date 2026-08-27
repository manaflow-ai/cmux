import AppKit
import Foundation
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Right sidebar panel registry")
struct RightSidebarPanelRegistryTests {
    @Test("Descriptors preserve the built-in panel order")
    func descriptorsPreserveBuiltInOrder() {
        let defaults = makeDefaults()
        let ids = RightSidebarPanelRegistry().descriptors.map(\.id)
        #expect(ids == ["files", "find", "sessions", "feed", "dock", "sourceControl"])
    }

    @Test("Source Control stays hidden until its beta flag is enabled")
    func sourceControlAvailabilityIsCatalogGated() {
        let defaults = makeDefaults()
        #expect(!RightSidebarMode.sourceControl.isAvailable(defaults: defaults))
        #expect(!RightSidebarPanelRegistry().availableModes(defaults: defaults).contains(.sourceControl))
        defaults.set(true, forKey: BetaFeaturesCatalogSection().sourceControl.userDefaultsKey)
        #expect(RightSidebarMode.sourceControl.isAvailable(defaults: defaults))
        #expect(RightSidebarMode.availableModes(defaults: defaults).contains(.sourceControl))
    }

    @Test("CLI aliases resolve through descriptor metadata")
    func cliAliasesResolveThroughDescriptors() {
        #expect(RightSidebarMode.from(cliArgument: "source-control") == .sourceControl)
        #expect(RightSidebarMode.from(cliArgument: "sourceControl") == .sourceControl)
        #expect(RightSidebarMode.from(cliArgument: "vault") == .sessions)
    }

    @Test("Existing pane eligibility remains descriptor-owned")
    func paneEligibilityRemainsStable() {
        #expect(RightSidebarMode.files.canOpenAsPane)
        #expect(RightSidebarMode.find.canOpenAsPane)
        #expect(RightSidebarMode.sessions.canOpenAsPane)
        #expect(!RightSidebarMode.sourceControl.canOpenAsPane)
    }

    @Test("Source Control shortcut is visible and remappable")
    func sourceControlShortcutIsPublicAndEditable() {
        let action = KeyboardShortcutSettings.Action.switchRightSidebarToSourceControl
        #expect(action.isPublicShortcutAction)
        #expect(KeyboardShortcutSettings.publicShortcutActions.contains(action))
        #expect(KeyboardShortcutSettings.settingsVisibleActions.contains(action))
        #expect(action.defaultShortcut.key == "6")
    }

    @Test("Source Control shortcut resolves through the registry matcher")
    @MainActor
    func sourceControlShortcutResolvesWhenAvailable() throws {
        let matcher = RightSidebarModeShortcutMatcher(
            availability: { $0 == .sourceControl }
        )
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "6",
                charactersIgnoringModifiers: "6",
                isARepeat: false,
                keyCode: 22
            )
        )
        #expect(matcher.modeShortcut(for: event, allowingAction: { _ in true }) == .sourceControl)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RightSidebarPanelRegistryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
