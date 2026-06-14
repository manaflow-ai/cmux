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
    @Test
    func commandPaletteIncludesDefaultRightSidebarModes() throws {
        try withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
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
                #expect(
                    contribution.subtitle(context) ==
                        String(localized: "command.rightSidebarMode.subtitle", defaultValue: "Right Sidebar")
                )
                #expect(contribution.keywords.contains("right"))
                #expect(contribution.keywords.contains("sidebar"))
                #expect(contribution.keywords.contains(mode.rawValue))
                #expect(contribution.when(context))
                #expect(contribution.enablement(context))
            }

            #expect(contributions.count == 3)
            #expect(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.feed)] == nil)
            #expect(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.dock)] == nil)
        }
    }

    @Test
    func feedModeCanOpenAsPane() {
        #expect(
            RightSidebarMode.feed.canOpenAsPane,
            "Feed mode should be openable as a pane so the header 'Open as Pane' button is visible, matching Files/Find/Vault"
        )
        #expect(RightSidebarMode.paneModes.contains(.feed))
        // Dock is a beta feature and intentionally stays excluded.
        #expect(!RightSidebarMode.dock.canOpenAsPane)
        #expect(!RightSidebarMode.paneModes.contains(.dock))
    }

    @Test
    func commandPaletteOffersOpenFeedAsPane() {
        withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)

            let descriptors = ContentView.commandPaletteRightSidebarToolPaneCommandDescriptors()
            #expect(
                descriptors.contains { $0.mode == .feed },
                "Command palette should expose an 'Open Feed as Pane' command when Feed is enabled, consistent with the header button"
            )
            #expect(
                !descriptors.contains { $0.mode == .dock },
                "Dock stays excluded from open-as-pane entrypoints"
            )
        }
    }

    @Test
    func commandPaletteHidesOpenFeedPaneWhenFeedDisabled() {
        withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)

            let descriptors = ContentView.commandPaletteRightSidebarToolPaneCommandDescriptors()
            #expect(
                !descriptors.contains { $0.mode == .feed },
                "Command palette should not expose Feed pane commands while the Feed beta feature is disabled"
            )
            #expect(
                !descriptors.contains { $0.mode == .dock },
                "Dock stays excluded from open-as-pane entrypoints"
            )
        }
    }

    @Test
    func feedPanePlacementDoesNotRegisterAsRightSidebarFocusHost() {
        #expect(FeedPanelView.Placement.rightSidebar.registersWithKeyboardFocusCoordinator)
        #expect(!FeedPanelView.Placement.pane.registersWithKeyboardFocusCoordinator)
    }

    @Test
    func commandPaletteRightSidebarActionsUseModeShortcutActions() {
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

    @Test
    func commandPaletteUnreadActionsUseConfigurableShortcutActions() {
        #expect(
            ContentView.commandPaletteShortcutAction(forCommandID: "palette.toggleUnread") ==
                .toggleUnread
        )
        #expect(
            ContentView.commandPaletteShortcutAction(forCommandID: "palette.markOldestUnreadAndJumpNext") ==
                .markOldestUnreadAndJumpNext
        )
    }

    private func withSavedBetaFeatureDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previousFeed = defaults.object(forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
        let previousDock = defaults.object(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
        defer {
            restore(previousFeed, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            restore(previousDock, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
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
