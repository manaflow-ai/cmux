import CmuxCommandPalette
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct RightSidebarCommandPaletteTests {
    @Test func commandPaletteIncludesDefaultRightSidebarModes() throws {
        try withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            let contributions = ContentView.commandPaletteRightSidebarModeCommandContributions()
            let contributionsByID = Dictionary(uniqueKeysWithValues: contributions.map { ($0.commandId, $0) })
            let context = CommandPaletteContextSnapshot()

            for mode in RightSidebarMode.availableModes() {
                let commandID = ContentView.commandPaletteRightSidebarModeCommandID(mode)
                let contribution = try #require(
                    contributionsByID[commandID],
                    "Expected command palette contribution for \(mode.rawValue)"
                )

                #expect(contribution.title(context) == (mode.shortcutAction?.label ?? mode.label))
                #expect(contribution.subtitle(context) == String(localized: "command.rightSidebarMode.subtitle", defaultValue: "Right Sidebar"))
                #expect(contribution.keywords.contains("right"))
                #expect(contribution.keywords.contains("sidebar"))
                #expect(contribution.keywords.contains(mode.rawValue))
                #expect(contribution.when(context))
                #expect(contribution.enablement(context))
            }

            #expect(contributions.count == 3)
            #expect(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.feed)] == nil)
            #expect(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.dock)] == nil)
            #expect(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.notes)] == nil)
        }
    }

    @Test func commandPaletteRightSidebarActionsUseModeShortcutActions() {
        withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)

            for mode in RightSidebarMode.allCases {
                #expect(
                    ContentView.commandPaletteShortcutAction(
                        forCommandID: ContentView.commandPaletteRightSidebarModeCommandID(mode)
                    ) == mode.shortcutAction
                )
            }
        }
    }

    @Test func commandPaletteUnreadActionsUseConfigurableShortcutActions() {
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.toggleUnread") == .toggleUnread)
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.markOldestUnreadAndJumpNext") == .markOldestUnreadAndJumpNext)
    }

    private func withSavedBetaFeatureDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previousFeed = defaults.object(forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
        let previousDock = defaults.object(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
        let previousNotes = defaults.object(forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
        defer {
            restore(previousFeed, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            restore(previousDock, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
            restore(previousNotes, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
        }
        try body()
    }

    private func restore(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
