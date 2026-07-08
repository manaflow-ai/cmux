import CmuxCommandPalette
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct RightSidebarCommandPaletteTests {
    @Test func testCommandPaletteIncludesDefaultRightSidebarModes() throws {
        try withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
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
                    contribution.subtitle(context)
                        == String(localized: "command.rightSidebarMode.subtitle", defaultValue: "Right Sidebar")
                )
                #expect(contribution.keywords.contains("right"))
                #expect(contribution.keywords.contains("sidebar"))
                #expect(contribution.keywords.contains(mode.rawValue))
                #expect(contribution.when(context))
                #expect(contribution.enablement(context))
            }

            // files, find, sessions are always available; notes/feed/dock are
            // beta features, off by default.
            #expect(contributions.count == 3)
            #expect(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.notes)] == nil)
            #expect(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.feed)] == nil)
            #expect(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.dock)] == nil)
        }
    }

    @Test func testCommandPaletteIncludesNotesWhenBetaEnabled() throws {
        try withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
            let contributions = ContentView.commandPaletteRightSidebarModeCommandContributions()
            let contributionsByID = Dictionary(uniqueKeysWithValues: contributions.map { ($0.commandId, $0) })
            #expect(contributions.count == 4)
            #expect(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.notes)] != nil)
        }
    }

    @Test func testCommandPaletteRightSidebarActionsUseModeShortcutActions() {
        withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
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

    @Test func testCommandPaletteUnreadActionsUseConfigurableShortcutActions() {
        #expect(
            ContentView.commandPaletteShortcutAction(forCommandID: "palette.toggleUnread")
                == .toggleUnread
        )
        #expect(
            ContentView.commandPaletteShortcutAction(forCommandID: "palette.markOldestUnreadAndJumpNext")
                == .markOldestUnreadAndJumpNext
        )
    }

    @Test func testNewNotePaletteCommandsRequireWorkspaceButNotNotesSidebarBeta() {
        var context = CommandPaletteContextSnapshot()
        #expect(
            !ContentView.commandPaletteNewNoteCommandsVisible(context),
            "New Note commands need a workspace target"
        )

        context.setBool(CommandPaletteContextKeys.notesBetaEnabled, false)
        #expect(!ContentView.commandPaletteNewNoteCommandsVisible(context))

        context.setBool(CommandPaletteContextKeys.hasWorkspace, true)
        #expect(ContentView.commandPaletteNewNoteCommandsVisible(context))
    }

    @Test func testNewNoteBuiltInActionAvailabilityDoesNotFollowNotesSidebarBeta() {
        withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            #expect(CmuxSurfaceTabBarBuiltInAction.newNote.isAvailable(defaults: defaults))

            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            #expect(CmuxSurfaceTabBarBuiltInAction.newNote.isAvailable(defaults: defaults))
        }
    }

    @Test func testRightSidebarNotesBuiltInActionFollowsNotesSidebarBeta() {
        withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            #expect(!CmuxSurfaceTabBarBuiltInAction.rightSidebarNotes.isAvailable(defaults: defaults))

            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            #expect(CmuxSurfaceTabBarBuiltInAction.rightSidebarNotes.isAvailable(defaults: defaults))
        }
    }

    private func withSavedBetaFeatureDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previousNotes = defaults.object(forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
        let previousFeed = defaults.object(forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
        let previousDock = defaults.object(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
        defer {
            restore(previousNotes, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
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
