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
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
            let contributions = ContentView.commandPaletteRightSidebarModeCommandContributions()
            let contributionsByID = Dictionary(uniqueKeysWithValues: contributions.map { ($0.commandId, $0) })
            let context = ContentView.CommandPaletteContextSnapshot()

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

            XCTAssertEqual(contributions.count, 4)
            XCTAssertNotNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.feed)])
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.dock)])
        }
    }

    func testFeedModeCanOpenAsPane() {
        XCTAssertTrue(
            RightSidebarMode.feed.canOpenAsPane,
            "Feed mode should be openable as a pane so the header 'Open as Pane' button is visible, matching Files/Find/Vault"
        )
        XCTAssertTrue(RightSidebarMode.paneModes.contains(.feed))
        // Dock is a beta feature and intentionally stays excluded.
        XCTAssertFalse(RightSidebarMode.dock.canOpenAsPane)
        XCTAssertFalse(RightSidebarMode.paneModes.contains(.dock))
    }

    func testCommandPaletteOffersOpenFeedAsPane() {
        let descriptors = ContentView.commandPaletteRightSidebarToolPaneCommandDescriptors()
        XCTAssertTrue(
            descriptors.contains { $0.mode == .feed },
            "Command palette should expose an 'Open Feed as Pane' command, consistent with the header button"
        )
        XCTAssertFalse(
            descriptors.contains { $0.mode == .dock },
            "Dock stays excluded from open-as-pane entrypoints"
        )
    }

    func testCommandPaletteRightSidebarActionsUseModeShortcutActions() {
        withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
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

    private func withSavedBetaFeatureDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previousDock = defaults.object(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
        defer {
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
