import CmuxCommandPalette
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RightSidebarCommandPaletteTests: XCTestCase {
    func testCommandPaletteIncludesDefaultRightSidebarModes() throws {
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
                let contribution = try XCTUnwrap(
                    contributionsByID[commandID],
                    "Expected command palette contribution for \(mode.rawValue)"
                )

                XCTAssertEqual(contribution.title(context), mode.shortcutAction?.label ?? mode.label)
                XCTAssertEqual(
                    contribution.subtitle(context),
                    String(localized: "command.rightSidebarMode.subtitle", defaultValue: "Right Sidebar")
                )
                XCTAssertTrue(contribution.keywords.contains("right"))
                XCTAssertTrue(contribution.keywords.contains("sidebar"))
                XCTAssertTrue(contribution.keywords.contains(mode.rawValue))
                XCTAssertTrue(contribution.when(context))
                XCTAssertTrue(contribution.enablement(context))
            }

            // files, find, sessions are always available; notes/feed/dock are
            // beta features, off by default.
            XCTAssertEqual(contributions.count, 3)
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.notes)])
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.feed)])
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.dock)])
        }
    }

    func testCommandPaletteIncludesNotesWhenBetaEnabled() throws {
        try withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
            let contributions = ContentView.commandPaletteRightSidebarModeCommandContributions()
            let contributionsByID = Dictionary(uniqueKeysWithValues: contributions.map { ($0.commandId, $0) })
            XCTAssertEqual(contributions.count, 4)
            XCTAssertNotNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.notes)])
        }
    }

    func testCommandPaletteRightSidebarActionsUseModeShortcutActions() {
        withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)

            for mode in RightSidebarMode.allCases {
                XCTAssertEqual(
                    ContentView.commandPaletteShortcutAction(
                        forCommandID: ContentView.commandPaletteRightSidebarModeCommandID(mode)
                    ),
                    mode.shortcutAction
                )
            }
        }
    }

    func testCommandPaletteUnreadActionsUseConfigurableShortcutActions() {
        XCTAssertEqual(
            ContentView.commandPaletteShortcutAction(forCommandID: "palette.toggleUnread"),
            .toggleUnread
        )
        XCTAssertEqual(
            ContentView.commandPaletteShortcutAction(forCommandID: "palette.markOldestUnreadAndJumpNext"),
            .markOldestUnreadAndJumpNext
        )
    }

    func testNewNotePaletteCommandsRequireWorkspaceButNotNotesSidebarBeta() {
        var context = CommandPaletteContextSnapshot()
        XCTAssertFalse(
            ContentView.commandPaletteNewNoteCommandsVisible(context),
            "New Note commands need a workspace target"
        )

        context.setBool(CommandPaletteContextKeys.notesBetaEnabled, false)
        XCTAssertFalse(ContentView.commandPaletteNewNoteCommandsVisible(context))

        context.setBool(CommandPaletteContextKeys.hasWorkspace, true)
        XCTAssertTrue(ContentView.commandPaletteNewNoteCommandsVisible(context))
    }

    func testNewNoteBuiltInActionAvailabilityDoesNotFollowNotesSidebarBeta() {
        withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            XCTAssertTrue(CmuxSurfaceTabBarBuiltInAction.newNote.isAvailable(defaults: defaults))

            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            XCTAssertTrue(CmuxSurfaceTabBarBuiltInAction.newNote.isAvailable(defaults: defaults))
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
