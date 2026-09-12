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
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
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

            // Files/Find/Vault are always present; Machines follows the Cloud
            // Machines beta toggle, which is off by default on every build
            // (cleared above) unless a managed profile forces Cloud off, and
            // feed/dock stay off.
            let machinesAvailable = RightSidebarMode.machines.isAvailable()
            XCTAssertFalse(machinesAvailable)
            XCTAssertEqual(contributions.count, 3)
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.feed)])
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.dock)])
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.machines)])
        }
    }

    func testCommandPaletteToolPaneCommandsCoverEveryAvailablePaneMode() throws {
        let descriptors = ContentView.commandPaletteRightSidebarToolPaneCommandDescriptors()
        let byMode = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.mode, $0) })
        XCTAssertEqual(
            Set(byMode.keys),
            Set(RightSidebarMode.paneModes.filter { $0.isAvailable() }),
            "Every pane-capable, available mode gets an Open-as-Pane palette command"
        )
        XCTAssertEqual(try XCTUnwrap(byMode[.files]).commandId, "palette.openFilesPane")
        XCTAssertEqual(try XCTUnwrap(byMode[.find]).commandId, "palette.openFindPane")
        XCTAssertEqual(try XCTUnwrap(byMode[.sessions]).commandId, "palette.openVaultPane")
        if RightSidebarMode.machines.isAvailable() {
            let cloud = try XCTUnwrap(byMode[.machines])
            XCTAssertEqual(cloud.commandId, "palette.openCloudPane")
            XCTAssertEqual(cloud.title, String(localized: "command.openCloudPane.title", defaultValue: "Open Cloud as Pane"))
        }
        XCTAssertEqual(Set(descriptors.map(\.commandId)).count, descriptors.count)
    }

    func testCommandPaletteRightSidebarActionsUseModeShortcutActions() {
        withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)

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
        let previousCloudMachines = defaults.object(forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        defer {
            restore(previousFeed, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            restore(previousDock, forKey: RightSidebarBetaFeatureSettings.dockEnabledKey)
            restore(previousCloudMachines, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
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
