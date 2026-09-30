import CmuxCommandPalette
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RightSidebarCommandPaletteTests: XCTestCase {
    func testStoredLegacyDockOptOutDoesNotHideDockCommand() throws {
        let defaults = UserDefaults.standard
        let key = "rightSidebar.beta.dock.enabled"
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        XCTAssertTrue(RightSidebarMode.availableModes().contains(.dock))
        XCTAssertTrue(
            ContentView.commandPaletteRightSidebarModeCommandContributions()
                .contains { $0.commandId == ContentView.commandPaletteRightSidebarModeCommandID(.dock) }
        )
    }

    func testDockIsAvailableForFreshAndExistingDefaultsWithoutStoredBetaValue() throws {
        let suiteNames = [
            "RightSidebarCommandPaletteTests.fresh.\(UUID().uuidString)",
            "RightSidebarCommandPaletteTests.existing.\(UUID().uuidString)",
        ]
        let defaults = try suiteNames.map { suiteName -> UserDefaults in
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            return defaults
        }
        defaults[1].set(true, forKey: "unrelated.existing.user.preference")
        defer {
            for (suiteName, suiteDefaults) in zip(suiteNames, defaults) {
                suiteDefaults.removePersistentDomain(forName: suiteName)
            }
        }

        for suiteDefaults in defaults {
            XCTAssertNil(suiteDefaults.object(forKey: "rightSidebar.beta.dock.enabled"))
            XCTAssertTrue(RightSidebarMode.dock.isAvailable(defaults: suiteDefaults))
            XCTAssertTrue(RightSidebarMode.availableModes(defaults: suiteDefaults).contains(.dock))
        }
    }

    func testCommandPaletteIncludesDefaultRightSidebarModes() throws {
        try withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            defaults.removeObject(forKey: "rightSidebar.beta.dock.enabled")
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

            // Files/Find/Vault and the graduated Dock are always present;
            // Machines follows the Cloud Machines beta toggle (pinned off above).
            let machinesAvailable = RightSidebarMode.machines.isAvailable()
            XCTAssertFalse(machinesAvailable)
            XCTAssertEqual(contributions.count, 4)
            XCTAssertNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.feed)])
            XCTAssertNotNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.dock)])
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

    func testCopyModeVisibilityFollowsTheTerminalTheShortcutWouldHit() {
        // Dock owns focus: its focused panel decides, whatever the main area holds.
        XCTAssertTrue(ContentView.commandPaletteShortcutTerminalFocused(
            focusedDockPanelIsTerminal: true,
            mainAreaPanelIsTerminal: false
        ))
        XCTAssertFalse(ContentView.commandPaletteShortcutTerminalFocused(
            focusedDockPanelIsTerminal: false,
            mainAreaPanelIsTerminal: true
        ))
        // Main area owns focus.
        XCTAssertTrue(ContentView.commandPaletteShortcutTerminalFocused(
            focusedDockPanelIsTerminal: nil,
            mainAreaPanelIsTerminal: true
        ))
        XCTAssertFalse(ContentView.commandPaletteShortcutTerminalFocused(
            focusedDockPanelIsTerminal: nil,
            mainAreaPanelIsTerminal: false
        ))
    }

    func testCopyModeRestoresFocusToTheFocusedDockTerminal() {
        XCTAssertTrue(ContentView.commandPalettePostRunFocusFollowsFocusedDock(
            forCommandId: ShortcutParityPaletteCommand.toggleTerminalCopyMode.rawValue
        ))
        // Text box commands act on the main-area terminal, so their restore stays there.
        XCTAssertFalse(ContentView.commandPalettePostRunFocusFollowsFocusedDock(
            forCommandId: "palette.terminalFocusTextBoxInput"
        ))
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
        terminalContext.setBool(ContentView.commandPaletteShortcutTerminalFocusedKey, true)
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
            case .voice: workspaceContext
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
            .toggleVoiceDictation,
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

    func testVoiceDictationPaletteCommandDismissesBeforeRunning() {
        // Dictation pins its target from the first responder, so the palette
        // must restore pane focus before the command runs.
        XCTAssertTrue(
            ContentView.commandPaletteShouldDismissBeforeRun(
                forCommandId: ShortcutParityPaletteCommand.toggleVoiceDictation.rawValue
            )
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
        let previousLegacyDockBeta = defaults.object(forKey: "rightSidebar.beta.dock.enabled")
        let previousCloudMachines = defaults.object(forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        defer {
            restore(previousFeed, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
            restore(previousLegacyDockBeta, forKey: "rightSidebar.beta.dock.enabled")
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
