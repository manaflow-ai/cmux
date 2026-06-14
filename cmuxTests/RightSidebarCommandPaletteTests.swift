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

            XCTAssertEqual(contributions.count, 3)
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.feed)])
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.dock)])
        }
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

    @MainActor
    func testShowRightSidebarModeUsesGlobalStateWhenNoMainWindowContextExists() {
        withSavedRightSidebarDefaults {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            let fileExplorerState = FileExplorerState()
            defer { AppDelegate.shared = previousAppDelegate }

            fileExplorerState.mode = .find
            fileExplorerState.setVisible(false)
            appDelegate.fileExplorerState = fileExplorerState

            XCTAssertTrue(
                appDelegate.showRightSidebarModeInActiveMainWindow(
                    mode: .files,
                    focusFirstItem: true,
                    preferredWindow: nil
                )
            )
            XCTAssertTrue(fileExplorerState.isVisible)
            XCTAssertEqual(fileExplorerState.mode, .files)
        }
    }

    @MainActor
    func testShowRightSidebarModeDoesNotMutateGlobalStateWhenRegisteredFocusFails() {
        withSavedRightSidebarDefaults {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            let fileExplorerState = FileExplorerState()
            defer { AppDelegate.shared = previousAppDelegate }

            fileExplorerState.mode = .find
            fileExplorerState.setVisible(false)
            appDelegate.fileExplorerState = fileExplorerState
            appDelegate.registerMainWindowContextForTesting(
                tabManager: TabManager(),
                fileExplorerState: nil
            )
            guard let context = appDelegate.mainWindowContexts.values.first else {
                XCTFail("Expected a registered main-window context")
                return
            }

            XCTAssertTrue(appDelegate.fileExplorerState === fileExplorerState)
            XCTAssertNil(context.fileExplorerState)
            XCTAssertFalse(
                context.keyboardFocusCoordinator.focusRightSidebar(
                    mode: .files,
                    focusFirstItem: true
                )
            )

            XCTAssertFalse(
                appDelegate.showRightSidebarModeInActiveMainWindow(
                    mode: .files,
                    focusFirstItem: true,
                    preferredWindow: nil
                )
            )
            XCTAssertFalse(fileExplorerState.isVisible)
            XCTAssertEqual(fileExplorerState.mode, .find)
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

    private func withSavedRightSidebarDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previousVisibility = defaults.object(forKey: "fileExplorer.isVisible")
        let previousMode = defaults.object(forKey: "rightSidebar.mode")
        defer {
            restore(previousVisibility, forKey: "fileExplorer.isVisible")
            restore(previousMode, forKey: "rightSidebar.mode")
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
