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

                XCTAssertEqual(contribution.title(context), mode.commandPaletteTitle)
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

            XCTAssertEqual(contributions.count, 5)
            XCTAssertNotNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.feed)])
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.dock)])
        }
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

    func testCommandPaletteRightSidebarToolPaneDescriptorsOnlyIncludePaneModes() {
        let descriptors = ContentView.commandPaletteRightSidebarToolPaneCommandDescriptors()
        let descriptorModes = descriptors.map(\.mode)

        XCTAssertEqual(descriptorModes, RightSidebarMode.paneModes)
        XCTAssertFalse(descriptorModes.contains(.goals))
        XCTAssertFalse(descriptorModes.contains(.feed))
        XCTAssertFalse(descriptorModes.contains(.dock))
    }

    func testCommandPaletteUnreadDeferActionUsesConfigurableShortcutAction() {
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
