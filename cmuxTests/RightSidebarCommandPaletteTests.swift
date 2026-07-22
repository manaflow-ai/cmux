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
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
            let contributions = ContentView.commandPaletteRightSidebarModeCommandContributions()
            let contributionsByID = Dictionary(uniqueKeysWithValues: contributions.map { ($0.commandId, $0) })
            let unavailableContext = CommandPaletteContextSnapshot()
            var panelWithoutPaneContext = CommandPaletteContextSnapshot()
            panelWithoutPaneContext.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
            var availableContext = CommandPaletteContextSnapshot()
            availableContext.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
            availableContext.setBool(CommandPaletteContextKeys.panelHasPane, true)

            for mode in RightSidebarMode.availableModes() {
                let commandID = ContentView.commandPaletteRightSidebarModeCommandID(mode)
                let contribution = try XCTUnwrap(
                    contributionsByID[commandID],
                    "Expected command palette contribution for \(mode.rawValue)"
                )

                XCTAssertEqual(contribution.title(availableContext), mode.shortcutAction?.label ?? mode.label)
                XCTAssertEqual(
                    contribution.subtitle(availableContext),
                    String(localized: "command.rightSidebarMode.subtitle", defaultValue: "Right Sidebar")
                )
                XCTAssertTrue(contribution.keywords.contains("right"))
                XCTAssertTrue(contribution.keywords.contains("sidebar"))
                XCTAssertTrue(contribution.keywords.contains(mode.rawValue))
                XCTAssertFalse(contribution.when(unavailableContext))
                XCTAssertFalse(contribution.when(panelWithoutPaneContext))
                XCTAssertTrue(contribution.when(availableContext))
                XCTAssertTrue(contribution.enablement(availableContext))
            }

            XCTAssertEqual(contributions.count, 3)
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.feed)])
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.dock)])
        }
    }

    func testRightSidebarToolPaneActionsRequireCapturedPanel() {
        let contributions = ContentView.commandPaletteRightSidebarToolPaneCommandContributions()
        let unavailableContext = CommandPaletteContextSnapshot()
        var panelWithoutPaneContext = CommandPaletteContextSnapshot()
        panelWithoutPaneContext.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
        var availableContext = CommandPaletteContextSnapshot()
        availableContext.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
        availableContext.setBool(CommandPaletteContextKeys.panelHasPane, true)

        XCTAssertFalse(contributions.isEmpty)
        for contribution in contributions {
            XCTAssertFalse(contribution.when(unavailableContext))
            XCTAssertFalse(contribution.when(panelWithoutPaneContext))
            XCTAssertTrue(contribution.when(availableContext))
        }
    }

    @MainActor
    func testRightSidebarRejectionsBeepOnlyForCommandPaletteInvocations() {
        var beeps = 0
        let automationResult = ContentView.commandPaletteRightSidebarRejected(
            .targetUnavailable,
            invocation: CmuxActionInvocation(source: .automation),
            beep: { beeps += 1 }
        )

        XCTAssertEqual(automationResult, .targetUnavailable)
        XCTAssertEqual(beeps, 0)

        let paletteResult = ContentView.commandPaletteRightSidebarRejected(
            .targetUnavailable,
            invocation: CmuxActionInvocation(source: .commandPalette),
            beep: { beeps += 1 }
        )

        XCTAssertEqual(paletteResult, .targetUnavailable)
        XCTAssertEqual(beeps, 1)
    }

    func testCommandPaletteRightSidebarActionsUseModeShortcutActions() {
        withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
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
