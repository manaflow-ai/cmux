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
            // Cloud Machines defaults on in dev builds (d6584c07e0); pin the toggle off so
            // the default-mode contract below is the same on every build.
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
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
            // Machines beta toggle (pinned off above), and feed/dock stay off.
            let machinesAvailable = RightSidebarMode.machines.isAvailable()
            XCTAssertFalse(machinesAvailable)
            XCTAssertEqual(contributions.count, 3)
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.feed)])
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.dock)])
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.machines)])
        }
    }

    @MainActor
    func testCommandPaletteRightSidebarActionsUseModeShortcutActions() {
        withSavedBetaFeatureDefaults {
            let definition = CmuxFeatureFlags.cloudMachinesFlag
            let previousOverride = CmuxFeatureFlags.shared.overrideValue(for: definition)
            CmuxFeatureFlags.shared.setOverride(true, for: definition)
            defer { CmuxFeatureFlags.shared.setOverride(previousOverride, for: definition) }
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

    @MainActor
    func testShortcutOnlyActionsHavePaletteCommandsLabeledAndBoundLikeTheirShortcuts() throws {
        let contributions = ContentView.commandPaletteShortcutParityContributions(
            workspaceSubtitle: { _ in "workspace" },
            terminalSubtitle: { _ in "terminal" },
            browserSubtitle: { _ in "browser" }
        )
        let contributionsByID = Dictionary(uniqueKeysWithValues: contributions.map { ($0.commandId, $0) })
        XCTAssertEqual(contributions.count, ShortcutParityPaletteCommand.allCases.count)

        var terminalContext = CommandPaletteContextSnapshot()
        terminalContext.setBool(CommandPaletteContextKeys.panelIsTerminal, true)
        var browserContext = CommandPaletteContextSnapshot()
        browserContext.setBool(CommandPaletteContextKeys.panelIsBrowser, true)
        var workspaceContext = CommandPaletteContextSnapshot()
        workspaceContext.setBool(CommandPaletteContextKeys.hasWorkspace, true)
        var splitsContext = CommandPaletteContextSnapshot()
        splitsContext.setBool(CommandPaletteContextKeys.workspaceHasSplits, true)
        let emptyContext = CommandPaletteContextSnapshot()

        for command in ShortcutParityPaletteCommand.allCases {
            let contribution = try XCTUnwrap(contributionsByID[command.rawValue], command.rawValue)
            XCTAssertEqual(contribution.title(emptyContext), command.shortcutAction.label)
            XCTAssertEqual(
                ContentView.commandPaletteShortcutAction(forCommandID: command.rawValue),
                command.shortcutAction
            )
            XCTAssertFalse(contribution.when(emptyContext), command.rawValue)
            let visibleContext: CommandPaletteContextSnapshot = switch command.scope {
            case .terminal: terminalContext
            case .browser: browserContext
            case .workspace: workspaceContext
            case .splits: splitsContext
            }
            XCTAssertTrue(contribution.when(visibleContext), command.rawValue)
        }

        let covered = Set(ShortcutParityPaletteCommand.allCases.map(\.shortcutAction))
        for action: KeyboardShortcutSettings.Action in [
            .toggleTerminalCopyMode,
            .increaseWorkspaceTerminalFontSize,
            .decreaseWorkspaceTerminalFontSize,
            .resetWorkspaceTerminalFontSize,
            .focusLeft, .focusRight, .focusUp, .focusDown,
            .focusPreviousPane, .focusNextPane,
            .groupSelectedWorkspaces,
            .toggleFocusedWorkspaceGroupCollapsed,
            .browserHardReload,
        ] {
            XCTAssertTrue(covered.contains(action), action.rawValue)
        }
        XCTAssertEqual(
            ContentView.commandPaletteShortcutAction(
                forCommandID: WorkspaceTodoPaletteCommands.cycleWorkspaceStatusCommandId
            ),
            .cycleWorkspaceStatus
        )
    }

    @MainActor
    func testBrowserHardReloadPaletteCommandDispatchesHardReload() {
        var dispatched: [BrowserAction] = []
        let handled = ContentView.performShortcutParityCommand(
            .browserHardReload,
            performBrowserAction: { action in
                dispatched.append(action)
                return true
            },
            preferredWindow: nil
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(dispatched.count, 1)
        guard case .hardReload = dispatched.first else {
            return XCTFail("expected .hardReload, got \(String(describing: dispatched.first))")
        }
    }

    @MainActor
    func testPaletteAndShortcutPaneFocusCycleSharesMainAreaPath() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let initialPanelID = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertNotNil(workspace.newTerminalSplit(from: initialPanelID, orientation: .horizontal, focus: false))
        let initialPaneID = workspace.bonsplitController.focusedPaneId

        XCTAssertTrue(AppDelegate.moveMainAreaPaneFocus(.next, tabManager: manager, window: nil))
        let movedPaneID = workspace.bonsplitController.focusedPaneId
        XCTAssertNotEqual(movedPaneID, initialPaneID)

        XCTAssertTrue(AppDelegate.moveMainAreaPaneFocus(.previous, tabManager: manager, window: nil))
        XCTAssertEqual(workspace.bonsplitController.focusedPaneId, initialPaneID)

        XCTAssertFalse(AppDelegate.moveMainAreaPaneFocus(.next, tabManager: nil, window: nil))
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
