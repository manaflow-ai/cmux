import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RightSidebarCommandPaletteTests: XCTestCase {
    func testCommandPaletteIncludesActionForEachRightSidebarMode() throws {
        let contributions = ContentView.commandPaletteRightSidebarModeCommandContributions()
        let contributionsByID = Dictionary(uniqueKeysWithValues: contributions.map { ($0.commandId, $0) })
        let context = ContentView.CommandPaletteContextSnapshot()

        for mode in RightSidebarMode.allCases {
            let commandID = ContentView.commandPaletteRightSidebarModeCommandID(mode)
            let contribution = try XCTUnwrap(
                contributionsByID[commandID],
                "Expected command palette contribution for \(mode.rawValue)"
            )

            XCTAssertEqual(contribution.title(context), mode.shortcutAction.label)
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

        XCTAssertEqual(contributions.count, RightSidebarMode.allCases.count)
    }

    func testCommandPaletteRightSidebarActionsUseModeShortcutActions() {
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
