import XCTest
import CmuxCore
import AppKit
import CmuxFoundation
import CmuxTerminalCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import CmuxPanes
import CmuxSettings
import CmuxWorkspaces
import CmuxSidebar
import UserNotifications
import Combine
import CmuxTerminal
import CmuxBrowser
import CMUXAgentLaunch
import struct CmuxSettings.IntegrationsCatalogSection
import enum CmuxSettings.KiroNotificationLevel

#if canImport(cmux_DEV)
@testable import cmux_DEV
// The app target still declares legacy duplicates of these CmuxSettings
// value types; with CmuxSettings imported unconditionally the names are
// ambiguous. These tests exercise the app-side paths, so pin the app types.
private typealias StoredShortcut = cmux_DEV.StoredShortcut
private typealias ShortcutStroke = cmux_DEV.ShortcutStroke
// `AppIconMode` now lives only in CmuxSettings (the app-target duplicate was
// drained); pin the package type for these app-side paths.
private typealias AppIconMode = CmuxSettings.AppIconMode
#elseif canImport(cmux)
@testable import cmux
private typealias StoredShortcut = cmux.StoredShortcut
private typealias ShortcutStroke = cmux.ShortcutStroke
private typealias AppIconMode = CmuxSettings.AppIconMode
#endif

@MainActor
func makeTemporaryBrowserProfile(named prefix: String) throws -> BrowserProfileDefinition {
    try XCTUnwrap(
        BrowserProfileStore.shared.createProfile(
            named: "\(prefix)-\(UUID().uuidString)"
        )
    )
}

final class SidebarSelectedWorkspaceColorTests: XCTestCase {
    func testLightModeUsesConfiguredSelectedWorkspaceBackgroundColor() {
        guard let color = sidebarSelectedWorkspaceBackgroundNSColor(for: .light).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 136.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testDarkModeUsesConfiguredSelectedWorkspaceBackgroundColor() {
        guard let color = sidebarSelectedWorkspaceBackgroundNSColor(for: .dark).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 145.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testSelectedWorkspaceForegroundUsesBlackOnLightSelectionBackground() {
        guard let color = sidebarSelectedWorkspaceForegroundNSColor(
            on: NSColor(hex: "#FFFFFF")!,
            opacity: 0.65
        ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.65, accuracy: 0.001)
    }

    func testSelectedWorkspaceForegroundUsesWhiteOnDarkSelectionBackground() {
        guard let color = sidebarSelectedWorkspaceForegroundNSColor(
            on: NSColor(hex: "#123456")!,
            opacity: 0.65
        ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.65, accuracy: 0.001)
    }

    func testDefaultSelectedWorkspaceForegroundUsesNativeSelectionTextOnAccentBackground() {
        guard let color = sidebarSelectedWorkspaceForegroundNSColor(
            on: sidebarSelectedWorkspaceBackgroundNSColor(for: .light),
            opacity: 0.65
        ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(color.redComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.65, accuracy: 0.001)
    }

    @MainActor
    func testSolidFillKeepsSelectedBackgroundForActiveCustomColoredWorkspaceRow() {
        let manager = TabManager()
        guard let workspace = manager.tabs.first else {
            XCTFail("Expected TabManager to initialise with a workspace")
            return
        }

        var observedSidebarInvalidation = false
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            observedSidebarInvalidation = true
        }
        observedSidebarInvalidation = false

        manager.setTabColor(tabId: workspace.id, color: "#C0392B")

        XCTAssertEqual(workspace.customColor, "#C0392B")
        XCTAssertTrue(observedSidebarInvalidation)

        let background = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .solidFill,
            isActive: true,
            isMultiSelected: false,
            customColorHex: workspace.customColor,
            colorScheme: .light,
            sidebarSelectionColorHex: nil
        )

        XCTAssertEqual(
            background.color?.hexString(),
            sidebarSelectedWorkspaceBackgroundNSColor(for: .light).hexString()
        )
        XCTAssertEqual(background.opacity, 1.0, accuracy: 0.001)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testLeftRailKeepsSelectedBackgroundForActiveCustomColoredWorkspaceRow() {
        let manager = TabManager()
        guard let workspace = manager.tabs.first else {
            XCTFail("Expected TabManager to initialise with a workspace")
            return
        }

        var observedSidebarInvalidation = false
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            observedSidebarInvalidation = true
        }
        observedSidebarInvalidation = false

        manager.setTabColor(tabId: workspace.id, color: "#C0392B")

        XCTAssertEqual(workspace.customColor, "#C0392B")
        XCTAssertTrue(observedSidebarInvalidation)

        let background = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .leftRail,
            isActive: true,
            isMultiSelected: false,
            customColorHex: workspace.customColor,
            colorScheme: .light,
            sidebarSelectionColorHex: nil
        )

        XCTAssertEqual(
            background.color?.hexString(),
            sidebarSelectedWorkspaceBackgroundNSColor(for: .light).hexString()
        )
        XCTAssertEqual(background.opacity, 1.0, accuracy: 0.001)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testLeftRailLeavesInactiveCustomColoredWorkspaceRowTransparent() {
        let manager = TabManager()
        guard let workspace = manager.tabs.first else {
            XCTFail("Expected TabManager to initialise with a workspace")
            return
        }

        manager.setTabColor(tabId: workspace.id, color: "#C0392B")

        let background = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .leftRail,
            isActive: false,
            isMultiSelected: false,
            customColorHex: workspace.customColor,
            colorScheme: .light,
            sidebarSelectionColorHex: nil
        )

        XCTAssertNil(background.color)
        XCTAssertEqual(background.opacity, 0, accuracy: 0.001)
    }

    @MainActor
    func testLeftRailResolvesExplicitRailColorForCustomColoredWorkspaceRow() {
        let manager = TabManager()
        guard let workspace = manager.tabs.first else {
            XCTFail("Expected TabManager to initialise with a workspace")
            return
        }

        manager.setTabColor(tabId: workspace.id, color: "#C0392B")

        let railColor = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: .leftRail,
            customColorHex: workspace.customColor,
            colorScheme: .light
        )

        XCTAssertNotNil(railColor)
        XCTAssertEqual(railColor?.hexString(), "#C0392B")
    }

    @MainActor
    func testSolidFillUsesInactiveCustomWorkspaceColorAsBackground() {
        let manager = TabManager()
        guard let workspace = manager.tabs.first else {
            XCTFail("Expected TabManager to initialise with a workspace")
            return
        }

        manager.setTabColor(tabId: workspace.id, color: "#C0392B")

        let background = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: .solidFill,
            isActive: false,
            isMultiSelected: false,
            customColorHex: workspace.customColor,
            colorScheme: .light,
            sidebarSelectionColorHex: nil
        )

        XCTAssertEqual(background.color?.hexString(), "#C0392B")
        XCTAssertEqual(background.opacity, 0.7, accuracy: 0.001)
    }

    @MainActor
    func testBatchWorkspaceColorAppliesOnlyRequestedWorkspaces() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.applyWorkspaceColor("#C0392B", toWorkspaceIds: [second.id])

        manager.applyWorkspaceColor("#1565C0", toWorkspaceIds: [first.id, third.id])

        XCTAssertEqual(first.customColor, "#1565C0")
        XCTAssertEqual(second.customColor, "#C0392B")
        XCTAssertEqual(third.customColor, "#1565C0")
    }

    @MainActor
    func testMoveFocusRoutesSpatiallyInCanvasMode() throws {
        let workspace = Workspace()
        let firstPanelId = try XCTUnwrap(workspace.orderedPanelIds.first)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let secondPanel = try XCTUnwrap(
            workspace.splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: .horizontal,
                insertFirst: false,
                workingDirectory: nil,
                initialInput: nil
            )
        )

        workspace.setLayoutMode(.canvas)
        // Pin deterministic canvas geometry: first pane left, second right.
        workspace.canvasModel.restoreFrames([
            (id: firstPanelId, frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            (id: secondPanel.id, frame: CGRect(x: 500, y: 0, width: 400, height: 300)),
        ])
        workspace.focusPanel(firstPanelId)

        workspace.moveFocus(direction: .right)
        XCTAssertEqual(
            workspace.focusedPanelId,
            secondPanel.id,
            "Canvas mode routes moveFocus through spatial navigation"
        )

        workspace.moveFocus(direction: .left)
        XCTAssertEqual(workspace.focusedPanelId, firstPanelId)

        // No pane further right: focus stays put instead of wrapping.
        workspace.moveFocus(direction: .left)
        XCTAssertEqual(workspace.focusedPanelId, firstPanelId)
    }

    @MainActor
    func testBatchWorkspaceTerminalScrollBarVisibilityAppliesOnlyRequestedWorkspaces() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setWorkspaceTerminalScrollBarHidden(hidden: true, forWorkspaceIds: [first.id, second.id, third.id])

        manager.setWorkspaceTerminalScrollBarHidden(hidden: false, forWorkspaceIds: [first.id, third.id])

        XCTAssertFalse(first.terminalScrollBarHidden)
        XCTAssertTrue(second.terminalScrollBarHidden)
        XCTAssertFalse(third.terminalScrollBarHidden)
    }
}


final class WorkspaceRenameShortcutDefaultsTests: XCTestCase {
    func testRenameTabShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.label, "Rename Tab")
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameTab.defaultsKey, "shortcut.renameTab")

        let shortcut = KeyboardShortcutSettings.Action.renameTab.defaultShortcut
        XCTAssertEqual(shortcut.key, "r")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testCloseWindowShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWindow.label, "Close Window")
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWindow.defaultsKey, "shortcut.closeWindow")

        let shortcut = KeyboardShortcutSettings.Action.closeWindow.defaultShortcut
        XCTAssertEqual(shortcut.key, "w")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertTrue(shortcut.control)
    }

    func testRenameWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameWorkspace.label, "Rename Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.renameWorkspace.defaultsKey, "shortcut.renameWorkspace")

        let shortcut = KeyboardShortcutSettings.Action.renameWorkspace.defaultShortcut
        XCTAssertEqual(shortcut.key, "r")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testRenameWorkspaceShortcutConvertsToMenuShortcut() {
        let shortcut = KeyboardShortcutSettings.Action.renameWorkspace.defaultShortcut
        XCTAssertNotNil(shortcut.keyEquivalent)
        XCTAssertTrue(shortcut.eventModifiers.contains(.command))
        XCTAssertTrue(shortcut.eventModifiers.contains(.shift))
        XCTAssertFalse(shortcut.eventModifiers.contains(.option))
        XCTAssertFalse(shortcut.eventModifiers.contains(.control))
    }

    func testCloseWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWorkspace.label, "Close Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.closeWorkspace.defaultsKey, "shortcut.closeWorkspace")

        let shortcut = KeyboardShortcutSettings.Action.closeWorkspace.defaultShortcut
        XCTAssertEqual(shortcut.key, "w")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testCloseWorkspaceShortcutConvertsToMenuShortcut() {
        let shortcut = KeyboardShortcutSettings.Action.closeWorkspace.defaultShortcut
        XCTAssertNotNil(shortcut.keyEquivalent)
        XCTAssertTrue(shortcut.eventModifiers.contains(.command))
        XCTAssertTrue(shortcut.eventModifiers.contains(.shift))
        XCTAssertFalse(shortcut.eventModifiers.contains(.option))
        XCTAssertFalse(shortcut.eventModifiers.contains(.control))
    }

    func testNextPreviousWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.nextSidebarTab.label, "Next Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.prevSidebarTab.label, "Previous Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.focusHistoryBack.label, "Focus Back")
        XCTAssertEqual(KeyboardShortcutSettings.Action.focusHistoryForward.label, "Focus Forward")
        XCTAssertEqual(KeyboardShortcutSettings.Action.nextSidebarTab.defaultsKey, "shortcut.nextSidebarTab")
        XCTAssertEqual(KeyboardShortcutSettings.Action.prevSidebarTab.defaultsKey, "shortcut.prevSidebarTab")
        XCTAssertEqual(KeyboardShortcutSettings.Action.focusHistoryBack.defaultsKey, "shortcut.focusHistoryBack")
        XCTAssertEqual(KeyboardShortcutSettings.Action.focusHistoryForward.defaultsKey, "shortcut.focusHistoryForward")

        let nextShortcut = KeyboardShortcutSettings.Action.nextSidebarTab.defaultShortcut
        XCTAssertEqual(nextShortcut.key, "]")
        XCTAssertTrue(nextShortcut.command)
        XCTAssertFalse(nextShortcut.shift)
        XCTAssertFalse(nextShortcut.option)
        XCTAssertTrue(nextShortcut.control)

        let prevShortcut = KeyboardShortcutSettings.Action.prevSidebarTab.defaultShortcut
        XCTAssertEqual(prevShortcut.key, "[")
        XCTAssertTrue(prevShortcut.command)
        XCTAssertFalse(prevShortcut.shift)
        XCTAssertFalse(prevShortcut.option)
        XCTAssertTrue(prevShortcut.control)

        let focusBackShortcut = KeyboardShortcutSettings.Action.focusHistoryBack.defaultShortcut
        XCTAssertEqual(focusBackShortcut.key, "[")
        XCTAssertTrue(focusBackShortcut.command)
        XCTAssertFalse(focusBackShortcut.shift)
        XCTAssertFalse(focusBackShortcut.option)
        XCTAssertFalse(focusBackShortcut.control)

        let focusForwardShortcut = KeyboardShortcutSettings.Action.focusHistoryForward.defaultShortcut
        XCTAssertEqual(focusForwardShortcut.key, "]")
        XCTAssertTrue(focusForwardShortcut.command)
        XCTAssertFalse(focusForwardShortcut.shift)
        XCTAssertFalse(focusForwardShortcut.option)
        XCTAssertFalse(focusForwardShortcut.control)

        XCTAssertTrue(KeyboardShortcutSettings.settingsVisibleActions.contains(.focusHistoryBack))
        XCTAssertTrue(KeyboardShortcutSettings.settingsVisibleActions.contains(.focusHistoryForward))
    }

    func testNextPreviousWorkspaceShortcutsConvertToMenuShortcut() {
        let nextShortcut = KeyboardShortcutSettings.Action.nextSidebarTab.defaultShortcut
        XCTAssertNotNil(nextShortcut.keyEquivalent)
        XCTAssertEqual(nextShortcut.menuItemKeyEquivalent, "]")
        XCTAssertTrue(nextShortcut.eventModifiers.contains(.command))
        XCTAssertTrue(nextShortcut.eventModifiers.contains(.control))

        let prevShortcut = KeyboardShortcutSettings.Action.prevSidebarTab.defaultShortcut
        XCTAssertNotNil(prevShortcut.keyEquivalent)
        XCTAssertEqual(prevShortcut.menuItemKeyEquivalent, "[")
        XCTAssertTrue(prevShortcut.eventModifiers.contains(.command))
        XCTAssertTrue(prevShortcut.eventModifiers.contains(.control))
    }

    func testToggleTerminalCopyModeShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.toggleTerminalCopyMode.label, "Toggle Terminal Copy Mode")
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleTerminalCopyMode.defaultsKey,
            "shortcut.toggleTerminalCopyMode"
        )

        let shortcut = KeyboardShortcutSettings.Action.toggleTerminalCopyMode.defaultShortcut
        XCTAssertEqual(shortcut.key, "m")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testSaveFilePreviewShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.saveFilePreview.label, "Save File Preview")
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.saveFilePreview.defaultsKey,
            "shortcut.saveFilePreview"
        )

        let shortcut = KeyboardShortcutSettings.Action.saveFilePreview.defaultShortcut
        XCTAssertEqual(shortcut.key, "s")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testRightSidebarAndFindShortcutDefaultsMatchSettingsSurface() {
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.focusRightSidebar.label,
            String(localized: "shortcut.focusRightSidebar.label", defaultValue: "Toggle Right Sidebar Focus")
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleRightSidebar.label,
            String(localized: "shortcut.toggleRightSidebar.label", defaultValue: "Toggle Right Sidebar")
        )

        let toggleRightSidebar = KeyboardShortcutSettings.Action.toggleRightSidebar.defaultShortcut
        XCTAssertEqual(toggleRightSidebar.key, "b")
        XCTAssertTrue(toggleRightSidebar.command)
        XCTAssertFalse(toggleRightSidebar.shift)
        XCTAssertTrue(toggleRightSidebar.option)
        XCTAssertFalse(toggleRightSidebar.control)

        let focusRightSidebar = KeyboardShortcutSettings.Action.focusRightSidebar.defaultShortcut
        XCTAssertEqual(focusRightSidebar.key, "e")
        XCTAssertTrue(focusRightSidebar.command)
        XCTAssertTrue(focusRightSidebar.shift)
        XCTAssertFalse(focusRightSidebar.option)
        XCTAssertFalse(focusRightSidebar.control)

        let findInDirectory = KeyboardShortcutSettings.Action.findInDirectory.defaultShortcut
        XCTAssertEqual(findInDirectory.key, "f")
        XCTAssertTrue(findInDirectory.command)
        XCTAssertTrue(findInDirectory.shift)
        XCTAssertFalse(findInDirectory.option)
        XCTAssertFalse(findInDirectory.control)
    }

    func testRightSidebarModeSwitchesHavePrivateControlDigitDefaults() {
        let modeSwitchActions: [(KeyboardShortcutSettings.Action, String)] = [
            (.switchRightSidebarToFiles, "1"),
            (.switchRightSidebarToFind, "2"),
            (.switchRightSidebarToSessions, "3"),
            (.switchRightSidebarToFeed, "4"),
            (.switchRightSidebarToDock, "5"),
        ]

        for (action, key) in modeSwitchActions {
            XCTAssertEqual(action.defaultShortcut.key, key)
            XCTAssertFalse(action.defaultShortcut.command)
            XCTAssertFalse(action.defaultShortcut.shift)
            XCTAssertFalse(action.defaultShortcut.option)
            XCTAssertTrue(action.defaultShortcut.control)
            XCTAssertFalse(action.isPublicShortcutAction)
            XCTAssertFalse(KeyboardShortcutSettings.publicShortcutActions.contains(action))
            XCTAssertFalse(KeyboardShortcutSettings.settingsVisibleActions.contains(action))
        }
    }

    func testSettingsVisibleShortcutActionsIncludeRemappableExampleShortcuts() {
        let visibleActions = Set(KeyboardShortcutSettings.settingsVisibleActions)

        XCTAssertTrue(visibleActions.contains(.toggleRightSidebar))
        XCTAssertTrue(visibleActions.contains(.focusRightSidebar))
        XCTAssertTrue(visibleActions.contains(.findInDirectory))
        XCTAssertTrue(visibleActions.contains(.toggleUnread))
        XCTAssertTrue(visibleActions.contains(.markOldestUnreadAndJumpNext))
        XCTAssertFalse(visibleActions.contains(.showHideAllWindows))
    }

    func testToggleUnreadUsesConfigurableCommandOptionUDefault() {
        let shortcut = KeyboardShortcutSettings.Action.toggleUnread.defaultShortcut

        XCTAssertEqual(shortcut.key, "u")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertTrue(shortcut.option)
        XCTAssertFalse(shortcut.control)
        XCTAssertTrue(KeyboardShortcutSettings.publicShortcutActions.contains(.toggleUnread))
        XCTAssertTrue(KeyboardShortcutSettings.settingsVisibleActions.contains(.toggleUnread))
    }

    func testMarkOldestUnreadAndJumpNextUsesConfigurableCommandControlUDefault() {
        let shortcut = KeyboardShortcutSettings.Action.markOldestUnreadAndJumpNext.defaultShortcut

        XCTAssertEqual(shortcut.key, "u")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertTrue(shortcut.control)
        XCTAssertTrue(KeyboardShortcutSettings.publicShortcutActions.contains(.markOldestUnreadAndJumpNext))
        XCTAssertTrue(KeyboardShortcutSettings.settingsVisibleActions.contains(.markOldestUnreadAndJumpNext))
    }

    func testSettingsVisibleShortcutActionsColocateRightSidebarFileExplorerAndFindShortcuts() {
        let visibleActions = KeyboardShortcutSettings.settingsVisibleActions
        let expectedActions: [KeyboardShortcutSettings.Action] = [
            .focusRightSidebar,
            .toggleRightSidebar,
            .findInDirectory,
        ]

        guard let startIndex = visibleActions.firstIndex(of: .focusRightSidebar) else {
            XCTFail("Toggle Right Sidebar Focus should be visible in keyboard shortcut settings")
            return
        }

        let endIndex = startIndex + expectedActions.count
        guard endIndex <= visibleActions.count else {
            XCTFail("Expected shortcut settings to include the full right-sidebar shortcut run")
            return
        }
        XCTAssertEqual(Array(visibleActions[startIndex..<endIndex]), expectedActions)
    }

    func testMenuItemKeyEquivalentHandlesArrowAndTabKeys() {
        XCTAssertNotNil(StoredShortcut(key: "←", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "→", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "↑", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertNotNil(StoredShortcut(key: "↓", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent)
        XCTAssertEqual(
            StoredShortcut(key: "\t", command: true, shift: false, option: false, control: false).menuItemKeyEquivalent,
            "\t"
        )
    }

    func testShortcutDefaultsKeysRemainUnique() {
        let keys = KeyboardShortcutSettings.Action.allCases.map(\.defaultsKey)
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testChordedShortcutDisplayDisablesMenuKeyEquivalent() {
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "d"
        )

        XCTAssertEqual(ShortcutDisplayFormatter().displayString(shortcut), "⌃B D")
        XCTAssertNil(shortcut.keyEquivalent)
        XCTAssertNil(shortcut.menuItemKeyEquivalent)
    }

    func testNumberedChordDisplayUsesChordSuffix() {
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "7"
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.selectWorkspaceByNumber.displayedShortcutString(for: shortcut),
            "⌃B 1…9"
        )
    }

    func testNumberedChordNormalizationTargetsSecondStroke() {
        let shortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "7"
        )

        let normalized = KeyboardShortcutSettings.Action.selectWorkspaceByNumber.normalizedRecordedShortcut(shortcut)
        XCTAssertEqual(normalized?.key, "b")
        XCTAssertEqual(normalized?.chordKey, "1")
    }

    func testStoredShortcutDecodesLegacySingleStrokePayload() throws {
        let data = """
        {"key":"d","command":true,"shift":false,"option":false,"control":false}
        """.data(using: .utf8)!

        let shortcut = try JSONDecoder().decode(FlatStoredShortcutPersistence.self, from: data).storedShortcut

        XCTAssertEqual(shortcut.key, "d")
        XCTAssertFalse(shortcut.hasChord)
        XCTAssertNil(shortcut.chordKey)
    }

    func testEscapeCancelDetectionTreatsEscapeCharacterAsCancelEvenWithUnexpectedKeyCode() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 36
        ) else {
            XCTFail("Failed to construct escape-like event")
            return
        }

        XCTAssertTrue(ShortcutStroke.isEscapeCancelEvent(event))
        XCTAssertNil(ShortcutStroke.from(event: event, requireModifier: false))
    }

    func testEscapeCancelDetectionAllowsModifiedEscapeGeneratingShortcut() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 33
        ) else {
            XCTFail("Failed to construct modified escape-generating event")
            return
        }

        XCTAssertFalse(ShortcutStroke.isEscapeCancelEvent(event))
        XCTAssertEqual(
            ShortcutStroke.from(event: event, requireModifier: false),
            ShortcutStroke(key: "[", command: true, shift: false, option: false, control: false, keyCode: 33)
        )
    }

    func testShortcutRecorderStopsRecordingWhenFirstStrokeConfirmationIsRejected() {
#if DEBUG
        let button = ShortcutRecorderNSButton(frame: .zero)
        button.transformRecordedShortcut = { _ in .rejected(.reservedBySystem) }
        button.debugSetPendingChordStart(
            ShortcutStroke(
                key: "x",
                command: true,
                shift: false,
                option: false,
                control: false
            )
        )

        button.performClick(nil)

        XCTAssertFalse(button.debugIsRecording)
#else
        XCTFail("Shortcut recorder debug hooks are only available in DEBUG")
#endif
    }

    func testShortcutRecorderCommitsAcceptedFirstStrokeImmediately() {
#if DEBUG
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        let button = ShortcutRecorderNSButton(frame: .zero)
        let recordedShortcut = StoredShortcut(
            key: "l",
            command: true,
            shift: true,
            option: false,
            control: false,
            keyCode: 37
        )
        var committedShortcut: StoredShortcut?
        var feedbackEvents: [ShortcutRecorderRejectedAttempt?] = []

        button.transformRecordedShortcut = { shortcut in
            XCTAssertEqual(shortcut, recordedShortcut)
            return .accepted(shortcut)
        }
        button.onShortcutRecorded = { committedShortcut = $0 }
        button.onRecorderFeedbackChanged = { feedbackEvents.append($0) }
        button.performClick(nil)

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "L",
            charactersIgnoringModifiers: "l",
            isARepeat: false,
            keyCode: 37
        ) else {
            XCTFail("Failed to construct Command-Shift-L event")
            return
        }

        XCTAssertNil(button.debugHandleRecordingEvent(event))
        XCTAssertEqual(committedShortcut, recordedShortcut)
        XCTAssertEqual(button.shortcut, recordedShortcut)
        XCTAssertFalse(button.debugIsRecording)
        XCTAssertTrue(feedbackEvents.contains { $0 == nil })
#else
        XCTFail("Shortcut recorder debug hooks are only available in DEBUG")
#endif
    }

    func testShortcutRecorderCapturesKeyEquivalentWhileRecording() {
#if DEBUG
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        let button = ShortcutRecorderNSButton(frame: .zero)
        let recordedShortcut = StoredShortcut(
            key: "t",
            command: true,
            shift: false,
            option: false,
            control: false,
            keyCode: 17
        )
        var committedShortcut: StoredShortcut?

        button.transformRecordedShortcut = { shortcut in
            XCTAssertEqual(shortcut, recordedShortcut)
            return .accepted(shortcut)
        }
        button.onShortcutRecorded = { committedShortcut = $0 }
        button.performClick(nil)

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "t",
            charactersIgnoringModifiers: "t",
            isARepeat: false,
            keyCode: 17
        ) else {
            XCTFail("Failed to construct Command-T event")
            return
        }

        XCTAssertTrue(button.performKeyEquivalent(with: event))
        XCTAssertEqual(committedShortcut, recordedShortcut)
        XCTAssertFalse(button.debugIsRecording)
#else
        XCTFail("Shortcut recorder debug hooks are only available in DEBUG")
#endif
    }

    func testShortcutRecorderStopAllNotificationStopsActiveRecorder() {
#if DEBUG
        let button = ShortcutRecorderNSButton(frame: .zero)
        button.debugSetPendingChordStart(
            ShortcutStroke(
                key: "l",
                command: true,
                shift: false,
                option: false,
                control: false
            )
        )

        KeyboardShortcutRecorderActivity.stopAllRecording()

        XCTAssertFalse(button.debugIsRecording)
#else
        XCTFail("Shortcut recorder debug hooks are only available in DEBUG")
#endif
    }
}

final class KeyboardShortcutSettingsFileStoreTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"

    func testShortcutConfigStringCanonicalizesNumberedDigitsWhenRequested() {
        let stroke = ShortcutStroke(
            key: "7",
            command: true,
            shift: false,
            option: false,
            control: false
        )

        XCTAssertEqual(stroke.configString(), "cmd+7")
        XCTAssertEqual(stroke.configString(preserveDigit: false), "cmd+1")
    }

    func testShortcutConfigParsingRoundTripsFunctionAndMediaKeys() {
        XCTAssertEqual(ShortcutStroke.parseConfig("cmd+f5")?.key, "f5")
        XCTAssertEqual(ShortcutStroke.parseConfig("cmd+media.playPause")?.key, "media.playPause")
        XCTAssertEqual(ShortcutStroke.parseConfig("cmd+playPause")?.key, "media.playPause")
        XCTAssertNil(ShortcutStroke.parseConfig("cmd+f21"))
    }

    override func setUp() {
        super.setUp()
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.resetAll()
        super.tearDown()
    }

    private var appIconModeKey: String { AppCatalogSection().appIcon.userDefaultsKey }

    func testSettingsFileStoreParsesSingleStrokeChordAndNumberedChord() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "toggleSidebar": "cmd+b",
                "newTab": ["ctrl+b", "c"],
                "selectWorkspaceByNumber": ["ctrl+b", "7"]
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .toggleSidebar),
            StoredShortcut(key: "b", command: true, shift: false, option: false, control: false)
        )
        XCTAssertEqual(
            store.override(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
        XCTAssertEqual(
            store.override(for: .selectWorkspaceByNumber),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "1")
        )
        XCTAssertEqual(store.activeSourcePath, settingsFileURL.path)
    }

    func testSettingsFileStoreAppliesSubagentNotificationSuppression() throws {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)
            } else {
                defaults.removeObject(forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }
        defaults.removeObject(forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "automation": {
                "suppressSubagentNotifications": false
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            defaults.object(forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey) as? Bool,
            false
        )
    }

    func testSettingsFileStoreInvalidKiroNotificationLevelDoesNotSkipLaterAutomationKeys() throws {
        let defaults = UserDefaults.standard
        let previousKiroLevel = defaults.object(forKey: IntegrationsCatalogSection().kiroNotificationLevel.userDefaultsKey)
        let previousPortBase = defaults.object(forKey: AutomationSettings.portBaseKey)
        let previousPortRange = defaults.object(forKey: AutomationSettings.portRangeKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousKiroLevel {
                defaults.set(previousKiroLevel, forKey: IntegrationsCatalogSection().kiroNotificationLevel.userDefaultsKey)
            } else {
                defaults.removeObject(forKey: IntegrationsCatalogSection().kiroNotificationLevel.userDefaultsKey)
            }
            if let previousPortBase {
                defaults.set(previousPortBase, forKey: AutomationSettings.portBaseKey)
            } else {
                defaults.removeObject(forKey: AutomationSettings.portBaseKey)
            }
            if let previousPortRange {
                defaults.set(previousPortRange, forKey: AutomationSettings.portRangeKey)
            } else {
                defaults.removeObject(forKey: AutomationSettings.portRangeKey)
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }
        defaults.removeObject(forKey: IntegrationsCatalogSection().kiroNotificationLevel.userDefaultsKey)
        defaults.removeObject(forKey: AutomationSettings.portBaseKey)
        defaults.removeObject(forKey: AutomationSettings.portRangeKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "automation": {
                "kiroNotificationLevel": "loud",
                "portBase": 32100,
                "portRange": 42
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertNil(defaults.object(forKey: IntegrationsCatalogSection().kiroNotificationLevel.userDefaultsKey))
        XCTAssertEqual(defaults.integer(forKey: AutomationSettings.portBaseKey), 32100)
        XCTAssertEqual(defaults.integer(forKey: AutomationSettings.portRangeKey), 42)
    }

    func testSettingsFileStoreAppliesBrowserHiddenWebViewDiscardDelayAtMaximum() throws {
        let defaults = UserDefaults.standard
        let previousEnabled = defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        let previousDelay = defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousEnabled {
                defaults.set(previousEnabled, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
            } else {
                defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
            }
            if let previousDelay {
                defaults.set(previousDelay, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            } else {
                defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }
        defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "browser": {
                "discardHiddenWebViews": false,
                "hiddenWebViewDiscardDelaySeconds": 3600
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey) as? Bool,
            false
        )
        XCTAssertEqual(
            defaults.double(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey),
            BrowserHiddenWebViewDiscardPolicy.maximumHiddenDelay
        )
    }

    func testSettingsFileStoreIgnoresBrowserHiddenWebViewDiscardDelayAboveMaximum() throws {
        let defaults = UserDefaults.standard
        let previousDelay = defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousDelay {
                defaults.set(previousDelay, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            } else {
                defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }
        defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "browser": {
                "hiddenWebViewDiscardDelaySeconds": 3601
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertNil(defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey))
    }

    func testSettingsFileStoreParsesRightSidebarShortcutBindings() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "focusRightSidebar": "cmd+opt+shift+e",
                "switchRightSidebarToFiles": "ctrl+4",
                "switchRightSidebarToFind": "ctrl+5",
                "switchRightSidebarToSessions": "ctrl+6",
                "switchRightSidebarToFeed": "ctrl+7",
                "switchRightSidebarToDock": "ctrl+8"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .focusRightSidebar),
            StoredShortcut(key: "e", command: true, shift: true, option: true, control: false)
        )
        XCTAssertEqual(
            store.override(for: .switchRightSidebarToFiles),
            StoredShortcut(key: "4", command: false, shift: false, option: false, control: true)
        )
        XCTAssertEqual(
            store.override(for: .switchRightSidebarToFind),
            StoredShortcut(key: "5", command: false, shift: false, option: false, control: true)
        )
        XCTAssertEqual(
            store.override(for: .switchRightSidebarToSessions),
            StoredShortcut(key: "6", command: false, shift: false, option: false, control: true)
        )
        XCTAssertEqual(
            store.override(for: .switchRightSidebarToFeed),
            StoredShortcut(key: "7", command: false, shift: false, option: false, control: true)
        )
        XCTAssertEqual(
            store.override(for: .switchRightSidebarToDock),
            StoredShortcut(key: "8", command: false, shift: false, option: false, control: true)
        )
    }

    func testSettingsFileStoreParsesWorkspaceWorkingDirectoryInheritanceSetting() throws {
        let defaults = UserDefaults.standard
        let managedKey = SettingCatalog().app.workspaceInheritWorkingDirectory.userDefaultsKey
        let previousValue = defaults.object(forKey: managedKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: managedKey)
            } else {
                defaults.removeObject(forKey: managedKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "workspaceInheritWorkingDirectory": false
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertFalse(UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().app.workspaceInheritWorkingDirectory))
    }

    func testInvalidForkConversationDefaultDoesNotAbortRemainingAppSettings() throws {
        let defaults = UserDefaults.standard
        let forkKey = AgentConversationForkDestination.defaultDestinationDefaultsKey
        let inheritanceKey = SettingCatalog().app.workspaceInheritWorkingDirectory.userDefaultsKey
        let previousForkValue = defaults.object(forKey: forkKey)
        let previousInheritanceValue = defaults.object(forKey: inheritanceKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousForkValue {
                defaults.set(previousForkValue, forKey: forkKey)
            } else {
                defaults.removeObject(forKey: forkKey)
            }
            if let previousInheritanceValue {
                defaults.set(previousInheritanceValue, forKey: inheritanceKey)
            } else {
                defaults.removeObject(forKey: inheritanceKey)
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: forkKey)
        defaults.removeObject(forKey: inheritanceKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "forkConversationDefaultDestination": "sideways",
                "workspaceInheritWorkingDirectory": false
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(AgentConversationForkDestination.configuredDefault(), .right)
        XCTAssertFalse(UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().app.workspaceInheritWorkingDirectory))
    }

    func testSettingsFileStoreParsesSidebarWorkspaceTitleWrapSetting() throws {
        let defaults = UserDefaults.standard
        let managedKey = SidebarWorkspaceTitleWrapSettings.key
        let previousValue = defaults.object(forKey: managedKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: managedKey)
            } else {
                defaults.removeObject(forKey: managedKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "sidebar": {
                "wrapWorkspaceTitles": true
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertTrue(SidebarWorkspaceTitleWrapSettings.wraps(defaults: defaults))
        XCTAssertEqual(defaults.object(forKey: SidebarWorkspaceTitleWrapSettings.key) as? Bool, true)
    }

    func testSettingsFileStoreDoesNotApplyAutomaticAppIconDuringStartupReplay() throws {
        let defaults = UserDefaults.standard
        let appIconModeKey = appIconModeKey
        let previousMode = defaults.object(forKey: appIconModeKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: appIconModeKey)
            } else {
                defaults.removeObject(forKey: appIconModeKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: appIconModeKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "appIcon": "automatic"
              }
            }
            """,
            to: settingsFileURL
        )

        // The managed-config reload path applies the icon through the shared
        // `appIconApplier`, which early-returns before any AppKit work because
        // `appIconLaunchReporter` reports not-finished-launching under XCTest.
        // The apply gating itself is covered in `AppIconSettingsTests`.
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.string(forKey: appIconModeKey), AppIconMode.automatic.rawValue)
    }

    func testSettingsFileStoreCanReplayAutomaticAppIconSettingTwiceWithoutTouchingAppKit() throws {
        let defaults = UserDefaults.standard
        let appIconModeKey = appIconModeKey
        let previousMode = defaults.object(forKey: appIconModeKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: appIconModeKey)
            } else {
                defaults.removeObject(forKey: appIconModeKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: appIconModeKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "appIcon": "automatic"
              }
            }
            """,
            to: settingsFileURL
        )

        // Replaying twice exercises the idempotent persist path; the shared
        // `appIconApplier` never touches AppKit because the launch reporter is
        // not finished-launching under XCTest.
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.string(forKey: appIconModeKey), AppIconMode.automatic.rawValue)
    }

    func testSettingsFileStoreRejectsModifierFreeFirstStroke() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "toggleSidebar": "b",
                "newTab": ["b", "c"],
                "splitRight": ["ctrl+b", "d"]
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertNil(store.override(for: .toggleSidebar))
        XCTAssertNil(store.override(for: .newTab))
        XCTAssertEqual(
            store.override(for: .splitRight),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "d")
        )
    }

    func testSettingsFileStoreUsesLegacyFallbackWhenCanonicalConfigHasNoSetting() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("primary.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("fallback.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-settings.schema.json",
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )

        let fallbackStore = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )
        XCTAssertEqual(
            fallbackStore.override(for: .showNotifications),
            StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
        )
        XCTAssertEqual(fallbackStore.activeSourcePath, primaryURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))

        try writeSettingsFile("{ not valid json", to: primaryURL)

        let invalidPrimaryStore = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )
        XCTAssertNil(invalidPrimaryStore.override(for: .showNotifications))
        XCTAssertEqual(invalidPrimaryStore.activeSourcePath, primaryURL.path)
    }

    func testPersistedShortcutOverridesSettingsFileShortcutValues() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "n", command: true, shift: false, option: false, control: false),
            for: .newTab
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.shortcut(for: .newTab),
            StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        )
        XCTAssertTrue(KeyboardShortcutSettings.isManagedBySettingsFile(.newTab))
    }

    @MainActor
    func testReloadConfigurationReloadsShortcutSettingsFile() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": "cmd+n"
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.shortcut(for: .newTab),
            StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        )

        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        GhosttyApp.shared.reloadConfiguration(source: "test.reload_config")

        XCTAssertEqual(
            KeyboardShortcutSettings.shortcut(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
    }

    @MainActor
    func testReloadConfigurationMenuActionReloadsRegisteredCmuxConfigStore() throws {
#if DEBUG
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "actions": {
                "first": { "type": "command", "command": "echo first" }
              }
            }
            """,
            to: settingsFileURL
        )

        let tabManager = TabManager()
        let cmuxConfigStore = CmuxConfigStore(
            globalConfigPath: settingsFileURL.path,
            startFileWatchers: false
        )
        cmuxConfigStore.wireDirectoryTracking(tabManager: tabManager)
        cmuxConfigStore.loadAll()
        XCTAssertNotNil(cmuxConfigStore.resolvedAction(id: "first"))
        XCTAssertNil(cmuxConfigStore.resolvedAction(id: "second"))

        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let windowId = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            cmuxConfigStore: cmuxConfigStore
        )
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        let previousMainMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMainMenu }

        let mainMenu = NSMenu(title: "Main")
        let appMenuItem = NSMenuItem(title: "cmux", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "cmux")
        let originalReloadItem = NSMenuItem(
            title: String(localized: "menu.app.reloadConfiguration", defaultValue: "Reload Configuration"),
            action: NSSelectorFromString("swiftuiPrivateReloadAction:"),
            keyEquivalent: ""
        )
        appMenu.addItem(originalReloadItem)
        mainMenu.addItem(appMenuItem)
        mainMenu.setSubmenu(appMenu, for: appMenuItem)
        NSApp.mainMenu = mainMenu

        let selector = NSSelectorFromString("reloadConfigurationMenuItem:")
        XCTAssertTrue(
            appDelegate.responds(to: selector),
            "Reload Configuration menu item must have an AppKit selector-backed action path"
        )
        appDelegate.installReloadConfigurationMenuItemAction()
        XCTAssertTrue(originalReloadItem.target === appDelegate)
        XCTAssertEqual(originalReloadItem.action, selector)
        XCTAssertEqual(
            originalReloadItem.identifier,
            NSUserInterfaceItemIdentifier("com.cmux.reloadConfiguration")
        )

        let rebuiltReloadItem = NSMenuItem(
            title: originalReloadItem.title,
            action: NSSelectorFromString("swiftuiPrivateReloadAction:"),
            keyEquivalent: ""
        )
        appMenu.removeItem(originalReloadItem)
        appMenu.addItem(rebuiltReloadItem)
        appDelegate.menuNeedsUpdate(appMenu)
        XCTAssertTrue(rebuiltReloadItem.target === appDelegate)
        XCTAssertEqual(rebuiltReloadItem.action, selector)

        try writeSettingsFile(
            """
            {
              "actions": {
                "second": { "type": "command", "command": "echo second" }
              }
            }
            """,
            to: settingsFileURL
        )

        let unrelatedReloadItem = NSMenuItem(
            title: rebuiltReloadItem.title,
            action: NSSelectorFromString("swiftuiPrivateReloadAction:"),
            keyEquivalent: ""
        )
        let unrelatedMenu = NSMenu(title: "Unrelated")
        unrelatedMenu.addItem(unrelatedReloadItem)
        appDelegate.menuNeedsUpdate(unrelatedMenu)
        XCTAssertFalse(unrelatedReloadItem.target === appDelegate)
        XCTAssertNotEqual(unrelatedReloadItem.action, selector)

        XCTAssertTrue(NSApp.sendAction(selector, to: rebuiltReloadItem.target, from: rebuiltReloadItem))

        XCTAssertNil(cmuxConfigStore.resolvedAction(id: "first"))
        XCTAssertNotNil(cmuxConfigStore.resolvedAction(id: "second"))
#else
        throw XCTSkip("menu selector regression requires DEBUG app test helpers")
#endif
    }

    func testSettingsFileShortcutCanBeOverriddenFromUI() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        let missingSettingsFileURL = directoryURL.appendingPathComponent("missing.json", isDirectory: false)
        let editedShortcut = StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        let managedShortcut = StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")

        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newTab), managedShortcut)

        KeyboardShortcutSettings.setShortcut(
            editedShortcut,
            for: .newTab
        )

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newTab), editedShortcut)

        KeyboardShortcutSettings.resetShortcut(for: .newTab)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newTab), managedShortcut)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: missingSettingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertFalse(KeyboardShortcutSettings.isManagedBySettingsFile(.newTab))
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newTab), KeyboardShortcutSettings.Action.newTab.defaultShortcut)
    }

    func testSystemWideHotkeySettingsPreserveInvalidManagedShortcutWithoutFallingBackToDefault() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showHideAllWindows": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let invalidShortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "c"
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.settingsFileStore.override(for: .showHideAllWindows),
            invalidShortcut
        )
        XCTAssertTrue(SystemWideHotkeySettings.isManagedBySettingsFile())
        XCTAssertEqual(SystemWideHotkeySettings.shortcut(), invalidShortcut)
        XCTAssertNotEqual(SystemWideHotkeySettings.shortcut(), SystemWideHotkeySettings.defaultShortcut)
        XCTAssertNil(SystemWideHotkeySettings.shortcut().carbonHotKeyRegistration)
    }

    func testSystemWideHotkeyLegacyMigrationPreservesInvalidShortcut() throws {
        let invalidShortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "c"
        )
        let encodedShortcut = try XCTUnwrap(try? JSONEncoder().encode(FlatStoredShortcutPersistence(invalidShortcut)))
        let defaults = UserDefaults.standard
        defaults.set(encodedShortcut, forKey: SystemWideHotkeySettings.legacyShortcutKey)

        let migratedShortcut = SystemWideHotkeySettings.shortcut()

        XCTAssertEqual(migratedShortcut, invalidShortcut)
        XCTAssertNil(defaults.object(forKey: SystemWideHotkeySettings.legacyShortcutKey))

        let migratedData = try XCTUnwrap(
            defaults.data(forKey: KeyboardShortcutSettings.Action.showHideAllWindows.defaultsKey)
        )
        let storedShortcut = try XCTUnwrap(try? JSONDecoder().decode(FlatStoredShortcutPersistence.self, from: migratedData).storedShortcut)
        XCTAssertEqual(storedShortcut, invalidShortcut)
        XCTAssertNil(storedShortcut.carbonHotKeyRegistration)
    }

    func testBootstrapCreatesCommentedTemplateWhenPrimaryAndFallbackAreMissing() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL
            .appendingPathComponent(".config/cmux", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsFileURL.path))
        XCTAssertEqual(store.activeSourcePath, settingsFileURL.path)
        XCTAssertNil(store.override(for: .newTab))

        let contents = try String(contentsOf: settingsFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains(#""$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json""#))
        XCTAssertTrue(contents.contains(#""schemaVersion": 1,"#))
        XCTAssertTrue(contents.contains(#"//   "app" : {"#))
        XCTAssertTrue(contents.contains(#"//     "colors" : {"#))
        XCTAssertTrue(contents.contains(##"//       "Red" : "#C0392B""##))
        XCTAssertTrue(contents.contains(#"//   "shortcuts" : {"#))
    }

    func testSettingsFileURLForEditingPrefersInvalidPrimaryForRepair() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("primary/cmux.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("fallback/cmux.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fallbackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeSettingsFile("{ not valid json", to: primaryURL)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )

        XCTAssertEqual(store.settingsFileURLForEditing().path, primaryURL.path)
        XCTAssertEqual(store.activeSourcePath, primaryURL.path)
    }

    func testSettingsFileStoreParsesJSONCCommentsAndTrailingCommas() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
              "schemaVersion": 1,
              // tmux-like prefix
              "shortcuts": {
                "bindings": {
                  "newTab": [
                    "ctrl+b",
                    "c",
                  ],
                },
              },
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
    }

    func testFutureSchemaVersionStillParsesKnownFields() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "schemaVersion": 999,
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .showNotifications),
            StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
        )
    }

    func testManagedUserDefaultSettingRestoresBackedUpValueWhenFileSettingIsRemoved() throws {
        let defaults = UserDefaults.standard
        let managedKey = SettingCatalog().app.reorderOnNotification.userDefaultsKey
        let previousValue = defaults.object(forKey: managedKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: managedKey)
            } else {
                defaults.removeObject(forKey: managedKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.set(false, forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let managedSettingsURL = directoryURL.appendingPathComponent("managed.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "reorderOnNotification": true
              }
            }
            """,
            to: managedSettingsURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: managedSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.object(forKey: managedKey) as? Bool, true)

        let missingSettingsURL = directoryURL.appendingPathComponent("missing.json", isDirectory: false)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: missingSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.object(forKey: managedKey) as? Bool, false)
        XCTAssertNil(defaults.data(forKey: settingsFileBackupsDefaultsKey))
    }

    func testSettingsFileStoreAppliesWorkspaceColorDictionaryAndAllowsRemovingDefaults() throws {
        let defaults = UserDefaults.standard
        let previousPalette = defaults.dictionary(forKey: WorkspaceTabColorSettings.paletteKey) as? [String: String]
        let previousLegacyOverrides = defaults.dictionary(forKey: "workspaceTabColor.defaultOverrides") as? [String: String]
        let previousLegacyCustomColors = defaults.array(forKey: "workspaceTabColor.customColors") as? [String]
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            WorkspaceTabColorSettings.reset(defaults: defaults)
            if let previousPalette {
                defaults.set(previousPalette, forKey: WorkspaceTabColorSettings.paletteKey)
            }
            if let previousLegacyOverrides {
                defaults.set(previousLegacyOverrides, forKey: "workspaceTabColor.defaultOverrides")
            }
            if let previousLegacyCustomColors {
                defaults.set(previousLegacyCustomColors, forKey: "workspaceTabColor.customColors")
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        WorkspaceTabColorSettings.reset(defaults: defaults)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "workspaceColors": {
                "colors": {
                  "Blue": "#2244ff",
                  "Neon Mint": "#00f5d4"
                }
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let palette = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertEqual(palette.map(\.name), ["Blue", "Neon Mint"])
        XCTAssertEqual(palette.map(\.hex), ["#2244FF", "#00F5D4"])
    }

    func testManagedWorkspaceColorsRestoreLegacyPaletteWhenFileSettingIsRemoved() throws {
        let defaults = UserDefaults.standard
        let previousPalette = defaults.dictionary(forKey: WorkspaceTabColorSettings.paletteKey) as? [String: String]
        let previousLegacyOverrides = defaults.dictionary(forKey: "workspaceTabColor.defaultOverrides") as? [String: String]
        let previousLegacyCustomColors = defaults.array(forKey: "workspaceTabColor.customColors") as? [String]
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            WorkspaceTabColorSettings.reset(defaults: defaults)
            if let previousPalette {
                defaults.set(previousPalette, forKey: WorkspaceTabColorSettings.paletteKey)
            }
            if let previousLegacyOverrides {
                defaults.set(previousLegacyOverrides, forKey: "workspaceTabColor.defaultOverrides")
            }
            if let previousLegacyCustomColors {
                defaults.set(previousLegacyCustomColors, forKey: "workspaceTabColor.customColors")
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        WorkspaceTabColorSettings.reset(defaults: defaults)
        defaults.set(["Blue": "#010203"], forKey: "workspaceTabColor.defaultOverrides")
        defaults.set(["#778899"], forKey: "workspaceTabColor.customColors")
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let managedSettingsURL = directoryURL.appendingPathComponent("managed.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "workspaceColors": {
                "colors": {
                  "Neon Mint": "#00F5D4"
                }
              }
            }
            """,
            to: managedSettingsURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: managedSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(WorkspaceTabColorSettings.palette(defaults: defaults).map(\.name), ["Neon Mint"])

        let missingSettingsURL = directoryURL.appendingPathComponent("missing.json", isDirectory: false)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: missingSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let restored = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertEqual(restored.first(where: { $0.name == "Blue" })?.hex, "#010203")
        XCTAssertEqual(restored.first(where: { $0.name == "Custom 1" })?.hex, "#778899")
        XCTAssertNil(defaults.data(forKey: settingsFileBackupsDefaultsKey))
    }

    @MainActor
    func testReloadConfigurationReloadsManagedAppSettingsFromSettingsFile() throws {
        let defaults = UserDefaults.standard
        let managedKey = SettingCatalog().app.newWorkspacePlacement.userDefaultsKey
        let previousValue = defaults.object(forKey: managedKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: managedKey)
            } else {
                defaults.removeObject(forKey: managedKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "newWorkspacePlacement": "top"
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().app.newWorkspacePlacement), .top)

        try writeSettingsFile(
            """
            {
              "app": {
                "newWorkspacePlacement": "end"
              }
            }
            """,
            to: settingsFileURL
        )

        GhosttyApp.shared.reloadConfiguration(source: "test.reload_config_app_setting")

        XCTAssertEqual(UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().app.newWorkspacePlacement), .end)
    }

    @MainActor
    func testManagedWorkspacePlacementChangesDefaultInsertionBehavior() throws {
        let defaults = UserDefaults.standard
        let managedKey = SettingCatalog().app.newWorkspacePlacement.userDefaultsKey
        let previousValue = defaults.object(forKey: managedKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: managedKey)
            } else {
                defaults.removeObject(forKey: managedKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "newWorkspacePlacement": "top"
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let manager = TabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace(placementOverride: .end)
        let third = manager.addWorkspace(placementOverride: .end)
        manager.selectWorkspace(first)

        let inserted = manager.addWorkspace()

        XCTAssertEqual(manager.tabs.map(\.id), [inserted.id, first.id, second.id, third.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testSettingsFileStoreAppliesWorkspaceGroupNewWorkspacePlacement() throws {
        let defaults = UserDefaults.standard
        let managedKey = SettingCatalog().workspaceGroups.newWorkspacePlacement.userDefaultsKey
        let previousValue = defaults.object(forKey: managedKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: managedKey)
            } else {
                defaults.removeObject(forKey: managedKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "workspaceGroups": {
                "newWorkspacePlacement": "end"
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().workspaceGroups.newWorkspacePlacement), .end)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class StoredShortcutMatchingTests: XCTestCase {
    private func makeMediaKeyEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = [],
        keyState: UInt8 = 0x0A
    ) -> NSEvent? {
        let data1 = Int((UInt32(keyCode) << 16) | (UInt32(keyState) << 8))
        return NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: Int16(8),
            data1: data1,
            data2: -1
        )
    }

    func testMatchingIgnoresCapsLock() {
        let shortcut = StoredShortcut(key: "q", command: true, shift: false, option: false, control: false)

        XCTAssertTrue(
            shortcut.matches(
                keyCode: 12,
                modifierFlags: [.command, .capsLock],
                eventCharacter: "q",
                layoutCharacterProvider: { _, _ in nil }
            )
        )
    }

    func testMatchingUsesRecordedCharacterForRemappedCommandLetter() {
        let shortcut = StoredShortcut(key: "q", command: true, shift: false, option: false, control: false)

        XCTAssertTrue(
            shortcut.matches(
                keyCode: 13,
                modifierFlags: [.command],
                eventCharacter: "q",
                layoutCharacterProvider: { _, _ in nil }
            )
        )
        XCTAssertFalse(
            StoredShortcut(key: "w", command: true, shift: false, option: false, control: false).matches(
                keyCode: 13,
                modifierFlags: [.command],
                eventCharacter: "q",
                layoutCharacterProvider: { _, _ in nil }
            )
        )
    }

    func testCommandShortcutUsesPrintableEventLetterBeforePhysicalPunctuationFallback() {
        let jumpToUnread = StoredShortcut(key: "u", command: true, shift: true, option: false, control: false)
        let nextSurface = StoredShortcut(key: "]", command: true, shift: true, option: false, control: false)

        XCTAssertTrue(
            jumpToUnread.matches(
                keyCode: 30,
                modifierFlags: [.command, .shift],
                eventCharacter: "u",
                layoutCharacterProvider: { _, _ in "]" }
            )
        )
        XCTAssertFalse(
            nextSurface.matches(
                keyCode: 30,
                modifierFlags: [.command, .shift],
                eventCharacter: "u",
                layoutCharacterProvider: { _, _ in "]" }
            )
        )
    }

    func testCommandControlLetterCanUseLayoutFallbackForControlCharacter() {
        let markUnreadAndJump = StoredShortcut(key: "u", command: true, shift: false, option: false, control: true)

        XCTAssertTrue(
            markUnreadAndJump.matches(
                keyCode: 32,
                modifierFlags: [.command, .control],
                eventCharacter: "\u{15}",
                layoutCharacterProvider: { keyCode, _ in keyCode == 32 ? "u" : nil }
            )
        )
    }

    func testCommandControlLetterCanUseLayoutFallbackForPrintableEventCharacter() {
        let markUnreadAndJump = StoredShortcut(key: "u", command: true, shift: false, option: false, control: true)

        XCTAssertTrue(
            markUnreadAndJump.matches(
                keyCode: 32,
                modifierFlags: [.command, .control],
                eventCharacter: "g",
                layoutCharacterProvider: { keyCode, _ in keyCode == 32 ? "u" : nil }
            )
        )
    }

    func testCommandControlPunctuationDoesNotStealPrintableLetterShortcut() {
        let nextWorkspace = StoredShortcut(key: "]", command: true, shift: false, option: false, control: true)

        XCTAssertFalse(
            nextWorkspace.matches(
                keyCode: 30,
                modifierFlags: [.command, .control],
                eventCharacter: "u",
                layoutCharacterProvider: { _, _ in "]" }
            )
        )
    }

    func testMatchingTreatsKeypadEnterAsReturn() {
        let shortcut = StoredShortcut(key: "\r", command: true, shift: false, option: false, control: false)

        XCTAssertTrue(
            shortcut.matches(
                keyCode: 76,
                modifierFlags: [.command],
                eventCharacter: "\r",
                layoutCharacterProvider: { _, _ in nil }
            )
        )
    }

    func testMatchingFallsBackToLayoutCharacterForNonLatinInput() {
        let shortcut = StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)

        XCTAssertTrue(
            shortcut.matches(
                keyCode: 17,
                modifierFlags: [.command],
                eventCharacter: "е",
                layoutCharacterProvider: { keyCode, _ in
                    keyCode == 17 ? "t" : nil
                }
            )
        )
    }

    func testResolvedKeyCodeUsesCurrentLayoutWhenShortcutWasStoredByCharacter() {
        let stroke = ShortcutStroke(key: "q", command: true, shift: false, option: false, control: false)

        XCTAssertEqual(
            stroke.resolvedKeyCode(
                layoutCharacterProvider: { keyCode, flags in
                    guard flags == [.command] else { return nil }
                    switch keyCode {
                    case 12:
                        return "'"
                    case 13:
                        return "q"
                    default:
                        return nil
                    }
                }
            ),
            13
        )
    }

    func testResolvedKeyCodePrefersRecordedPhysicalKeyOverLayoutLookup() {
        let stroke = ShortcutStroke(key: "q", command: true, shift: false, option: false, control: false, keyCode: 13)

        XCTAssertEqual(
            stroke.resolvedKeyCode(
                layoutCharacterProvider: { keyCode, _ in
                    keyCode == 12 ? "q" : nil
                }
            ),
            13
        )
        XCTAssertEqual(stroke.carbonHotKeyRegistration?.keyCode, 13)
    }

    func testShortcutRecordingResultRejectsBareLetterWithoutModifier() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) else {
            XCTFail("Failed to construct bare letter event")
            return
        }

        XCTAssertEqual(
            ShortcutStroke.recordingResult(from: event, requireModifier: true),
            .rejected(.bareKeyNotAllowed)
        )
    }

    func testShortcutRecordingResultAcceptsBareFunctionKeyWithoutModifier() {
        let f1Characters = String(UnicodeScalar(NSF1FunctionKey)!)

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: f1Characters,
            charactersIgnoringModifiers: f1Characters,
            isARepeat: false,
            keyCode: 122
        ) else {
            XCTFail("Failed to construct F1 event")
            return
        }

        XCTAssertEqual(
            ShortcutStroke.recordingResult(from: event, requireModifier: true),
            .accepted(ShortcutStroke(key: "f1", command: false, shift: false, option: false, control: false, keyCode: 122))
        )
    }

    func testShortcutRecordingResultSafelyIgnoresNonMediaSystemDefinedEvent() {
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) else {
            XCTFail("Failed to construct non-media system-defined event")
            return
        }

        XCTAssertFalse(ShortcutStroke.isEscapeCancelEvent(event))
        XCTAssertEqual(
            ShortcutStroke.recordingResult(from: event, requireModifier: true),
            .unsupportedKey
        )
    }

    func testMediaShortcutDoesNotMatchOrdinaryKeyDownWithSameKeyCode() {
        let shortcut = ShortcutStroke(
            key: "media.volumeUp",
            command: false,
            shift: false,
            option: false,
            control: false,
            keyCode: 0
        )

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) else {
            XCTFail("Failed to construct A key event")
            return
        }

        XCTAssertFalse(shortcut.matches(event: event))
    }

    func testMediaShortcutMatchesSystemDefinedMediaEvent() {
        let shortcut = ShortcutStroke(
            key: "media.volumeUp",
            command: false,
            shift: false,
            option: false,
            control: false,
            keyCode: 0
        )

        guard let event = makeMediaKeyEvent(keyCode: 0) else {
            XCTFail("Failed to construct media key event")
            return
        }

        XCTAssertTrue(shortcut.matches(event: event))
    }

    func testShortcutRecorderResolutionReportsConflictingAction() {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        let shortcut = StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.openBrowser.normalizedRecordedShortcutResult(shortcut),
            .rejected(.conflictsWithAction(.newSurface))
        )
    }

    func testShortcutRecorderResolutionRejectsNumberedShortcutAgainstReservedDigitFamily() {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "3", command: true, shift: false, option: false, control: false),
            for: .openBrowser
        )

        let shortcut = StoredShortcut(key: "2", command: true, shift: false, option: false, control: false)

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.selectWorkspaceByNumber.normalizedRecordedShortcutResult(shortcut),
            .rejected(.conflictsWithAction(.openBrowser))
        )
    }

    func testShortcutRecorderResolutionRejectsSingleStrokeThatMatchesChordPrefix() {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                key: "k",
                command: true,
                shift: false,
                option: false,
                control: false,
                chordKey: "c",
                chordCommand: true,
                chordShift: false,
                chordOption: false,
                chordControl: false
            ),
            for: .openBrowser
        )

        let shortcut = StoredShortcut(key: "k", command: true, shift: false, option: false, control: false)

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.newTab.normalizedRecordedShortcutResult(shortcut),
            .rejected(.conflictsWithAction(.openBrowser))
        )
    }

    func testShortcutRecorderResolutionRejectsChordThatMatchesExistingSingleStrokePrefix() {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "k", command: true, shift: false, option: false, control: false),
            for: .openBrowser
        )

        let shortcut = StoredShortcut(
            key: "k",
            command: true,
            shift: false,
            option: false,
            control: false,
            chordKey: "c",
            chordCommand: true,
            chordShift: false,
            chordOption: false,
            chordControl: false
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.newTab.normalizedRecordedShortcutResult(shortcut),
            .rejected(.conflictsWithAction(.openBrowser))
        )
    }

    func testSystemWideHotkeyNormalizationReportsCmuxActionConflictByRecordedPhysicalKey() {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        let shortcut = StoredShortcut(
            key: "q",
            command: true,
            shift: false,
            option: false,
            control: false,
            keyCode: 13
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.showHideAllWindows.normalizedRecordedShortcutResult(shortcut),
            .rejected(.conflictsWithAction(.quit))
        )
    }

    func testSystemWideHotkeyNormalizationReportsReservedHotkeyReason() {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        let shortcut = StoredShortcut(key: ".", command: true, shift: false, option: false, control: false)

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.showHideAllWindows.normalizedRecordedShortcutResult(shortcut),
            .rejected(.reservedBySystem)
        )
    }

    func testShortcutRecorderValidationPresentationSurfacesBareKeyMessage() {
        let presentation = ShortcutRecorderValidationPresentation(
            attempt: ShortcutRecorderRejectedAttempt(reason: .bareKeyNotAllowed, proposedShortcut: nil),
            action: .openBrowser,
            currentShortcut: KeyboardShortcutSettings.Action.openBrowser.defaultShortcut
        )

        XCTAssertEqual(presentation?.message, "Shortcuts must include ⌘ ⌥ ⌃ or ⇧")
        XCTAssertNil(presentation?.swapButtonTitle)
        XCTAssertFalse(presentation?.canSwap ?? true)
        XCTAssertEqual(presentation?.undoButtonTitle, "Undo")
    }

    func testShortcutRecorderValidationPresentationSurfacesConflictActionAndSwapAffordance() {
        let presentation = ShortcutRecorderValidationPresentation(
            attempt: ShortcutRecorderRejectedAttempt(
                reason: .conflictsWithAction(.newSurface),
                proposedShortcut: StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)
            ),
            action: .openBrowser,
            currentShortcut: KeyboardShortcutSettings.Action.openBrowser.defaultShortcut,
            shortcutForAction: { $0.defaultShortcut }
        )

        XCTAssertEqual(presentation?.message, "This shortcut conflicts with New Surface (⌘T). Swap shortcuts?")
        XCTAssertEqual(presentation?.swapButtonTitle, "Swap")
        XCTAssertTrue(presentation?.canSwap ?? false)
        XCTAssertEqual(presentation?.undoButtonTitle, "Undo")
    }

    func testShortcutRecorderValidationPresentationUsesNumberedDisplayOnlyForNumberedConflicts() {
        let presentation = ShortcutRecorderValidationPresentation(
            attempt: ShortcutRecorderRejectedAttempt(
                reason: .conflictsWithAction(.selectWorkspaceByNumber),
                proposedShortcut: StoredShortcut(key: "2", command: true, shift: false, option: false, control: false)
            ),
            action: .openBrowser,
            currentShortcut: KeyboardShortcutSettings.Action.openBrowser.defaultShortcut,
            shortcutForAction: { $0.defaultShortcut }
        )

        XCTAssertEqual(
            presentation?.message,
            "This shortcut conflicts with Select Workspace 1…9 (⌘1…9)."
        )
        XCTAssertNil(presentation?.swapButtonTitle)
        XCTAssertFalse(presentation?.canSwap ?? true)
        XCTAssertEqual(presentation?.undoButtonTitle, "Undo")
    }

    func testShortcutRecorderValidationPresentationSurfacesReservedSystemMessage() {
        let presentation = ShortcutRecorderValidationPresentation(
            attempt: ShortcutRecorderRejectedAttempt(reason: .reservedBySystem, proposedShortcut: nil),
            action: .showHideAllWindows,
            currentShortcut: KeyboardShortcutSettings.Action.showHideAllWindows.defaultShortcut
        )

        XCTAssertEqual(presentation?.message, "This keystroke is reserved by macOS.")
        XCTAssertNil(presentation?.swapButtonTitle)
        XCTAssertFalse(presentation?.canSwap ?? true)
        XCTAssertEqual(presentation?.undoButtonTitle, "Undo")
    }
}


@MainActor
final class WorkspaceCustomDescriptionTests: XCTestCase {
    func testSetCustomDescriptionPreservesMeaningfulLeadingAndTrailingWhitespace() {
        let workspace = Workspace()
        let description = "  line one\n\nline two\n\n"

        workspace.setCustomDescription(description)

        XCTAssertEqual(workspace.customDescription, description)
        XCTAssertTrue(workspace.hasCustomDescription)
    }

    func testSetCustomDescriptionClearsWhitespaceOnlyDescriptions() {
        let workspace = Workspace()

        workspace.setCustomDescription(" \n\t \n")

        XCTAssertNil(workspace.customDescription)
        XCTAssertFalse(workspace.hasCustomDescription)
    }
}
final class WorkspacePlacementSettingsTests: XCTestCase {
    func testCurrentPlacementDefaultsToAfterCurrentWhenUnset() {
        let suiteName = "WorkspacePlacementSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().app.newWorkspacePlacement), .afterCurrent)
    }

    func testCurrentPlacementReadsStoredValidValueAndFallsBackForInvalid() {
        let suiteName = "WorkspacePlacementSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(WorkspacePlacement.top.rawValue, forKey: SettingCatalog().app.newWorkspacePlacement.userDefaultsKey)
        XCTAssertEqual(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().app.newWorkspacePlacement), .top)

        defaults.set("nope", forKey: SettingCatalog().app.newWorkspacePlacement.userDefaultsKey)
        XCTAssertEqual(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().app.newWorkspacePlacement), .afterCurrent)
    }

    func testInsertionIndexTopInsertsBeforeUnpinned() {
        let index = WorkspacePlacement.top.insertionIndex(
            selectedIndex: 4,
            selectedIsPinned: false,
            pinnedCount: 2,
            totalCount: 7
        )
        XCTAssertEqual(index, 2)
    }

    func testInsertionIndexAfterCurrentHandlesPinnedAndUnpinnedSelection() {
        let afterUnpinned = WorkspacePlacement.afterCurrent.insertionIndex(
            selectedIndex: 3,
            selectedIsPinned: false,
            pinnedCount: 2,
            totalCount: 6
        )
        XCTAssertEqual(afterUnpinned, 4)

        let afterPinned = WorkspacePlacement.afterCurrent.insertionIndex(
            selectedIndex: 0,
            selectedIsPinned: true,
            pinnedCount: 2,
            totalCount: 6
        )
        XCTAssertEqual(afterPinned, 2)
    }

    func testInsertionIndexEndAndNoSelectionAppend() {
        let endIndex = WorkspacePlacement.end.insertionIndex(
            selectedIndex: 1,
            selectedIsPinned: false,
            pinnedCount: 1,
            totalCount: 5
        )
        XCTAssertEqual(endIndex, 5)

        let noSelectionIndex = WorkspacePlacement.afterCurrent.insertionIndex(
            selectedIndex: nil,
            selectedIsPinned: false,
            pinnedCount: 0,
            totalCount: 5
        )
        XCTAssertEqual(noSelectionIndex, 5)
    }
}

final class WorkspaceWorkingDirectoryInheritanceSettingsTests: XCTestCase {
    func testDefaultsToEnabledWhenUnset() {
        let suiteName = "WorkspaceWorkingDirectoryInheritanceSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().app.workspaceInheritWorkingDirectory))
    }

    func testReadsStoredBooleanValue() {
        let suiteName = "WorkspaceWorkingDirectoryInheritanceSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: SettingCatalog().app.workspaceInheritWorkingDirectory.userDefaultsKey)
        XCTAssertFalse(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().app.workspaceInheritWorkingDirectory))

        defaults.set(true, forKey: SettingCatalog().app.workspaceInheritWorkingDirectory.userDefaultsKey)
        XCTAssertTrue(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().app.workspaceInheritWorkingDirectory))
    }
}

@MainActor
final class WorkspaceCreationWorkingDirectoryInheritanceTests: XCTestCase {
    private final class DetachedWorkspaceTestPanel: Panel {
        let objectWillChange = ObservableObjectPublisher()
        let id: UUID
        let panelType: PanelType = .terminal
        let displayTitle = "Detached"
        let displayIcon: String? = "terminal.fill"
        let isDirty = false

        init(id: UUID = UUID()) {
            self.id = id
        }

        func close() {}
        func focus() {}
        func unfocus() {}
        func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
    }

    func testNewWorkspaceInheritsSourceWorkingDirectoryByDefault() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(nil) {
            let sourceCwd = "/tmp/cmux-source-\(UUID().uuidString)"
            let manager = TabManager(
                initialWorkingDirectory: sourceCwd,
                autoWelcomeIfNeeded: false
            )

            let inserted = manager.addWorkspace(autoWelcomeIfNeeded: false)

            XCTAssertEqual(inserted.focusedTerminalPanel?.requestedWorkingDirectory, sourceCwd)
            XCTAssertEqual(inserted.currentDirectory, sourceCwd)
        }
    }

    func testDisabledInheritanceLeavesNewWorkspaceCwdUnsetForGhosttyConfigFallback() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(false) {
            let sourceCwd = "/tmp/cmux-source-\(UUID().uuidString)"
            let manager = TabManager(
                initialWorkingDirectory: sourceCwd,
                autoWelcomeIfNeeded: false
            )

            let inserted = manager.addWorkspace(autoWelcomeIfNeeded: false)

            XCTAssertNil(inserted.focusedTerminalPanel?.requestedWorkingDirectory)
            XCTAssertNotEqual(inserted.currentDirectory, sourceCwd)
        }
    }

    func testExplicitNoInheritanceLeavesNewWorkspaceCwdUnsetWhenGlobalInheritanceEnabled() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(nil) {
            let sourceCwd = "/tmp/cmux-source-\(UUID().uuidString)"
            let manager = TabManager(
                initialWorkingDirectory: sourceCwd,
                autoWelcomeIfNeeded: false
            )

            let inserted = manager.addWorkspace(
                inheritWorkingDirectory: false,
                autoWelcomeIfNeeded: false
            )

            XCTAssertNil(inserted.focusedTerminalPanel?.requestedWorkingDirectory)
            XCTAssertNotEqual(inserted.currentDirectory, sourceCwd)
        }
    }

    func testExplicitWorkspaceWorkingDirectoryWinsWhenInheritanceIsDisabled() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(false) {
            let sourceCwd = "/tmp/cmux-source-\(UUID().uuidString)"
            let explicitCwd = "/tmp/cmux-explicit-\(UUID().uuidString)"
            let manager = TabManager(
                initialWorkingDirectory: sourceCwd,
                autoWelcomeIfNeeded: false
            )

            let inserted = manager.addWorkspace(
                workingDirectory: explicitCwd,
                autoWelcomeIfNeeded: false
            )

            XCTAssertEqual(inserted.focusedTerminalPanel?.requestedWorkingDirectory, explicitCwd)
            XCTAssertEqual(inserted.currentDirectory, explicitCwd)
        }
    }

    func testDetachedWorkspaceInheritsSourceWorkingDirectoryByDefaultWhenTransferHasNoDirectory() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(nil) {
            let sourceCwd = "/tmp/cmux-source-\(UUID().uuidString)"
            let manager = TabManager(
                initialWorkingDirectory: sourceCwd,
                autoWelcomeIfNeeded: false
            )
            let source = try XCTUnwrap(manager.selectedWorkspace)
            let detached = makeDetachedWorkspaceTestTransfer(sourceWorkspaceId: source.id)

            let inserted = try XCTUnwrap(manager.addWorkspace(
                fromDetachedSurface: detached,
                select: false
            ))

            XCTAssertEqual(inserted.currentDirectory, sourceCwd)
            XCTAssertEqual(inserted.surfaceTabBarDirectory, sourceCwd)
        }
    }

    func testDisabledInheritanceLeavesDetachedWorkspaceFallbackCwdUnsetWhenTransferHasNoDirectory() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(false) {
            let sourceCwd = "/tmp/cmux-source-\(UUID().uuidString)"
            let fallbackCwd = FileManager.default.homeDirectoryForCurrentUser.path
            let manager = TabManager(
                initialWorkingDirectory: sourceCwd,
                autoWelcomeIfNeeded: false
            )
            let source = try XCTUnwrap(manager.selectedWorkspace)
            let detached = makeDetachedWorkspaceTestTransfer(sourceWorkspaceId: source.id)

            let inserted = try XCTUnwrap(manager.addWorkspace(
                fromDetachedSurface: detached,
                select: false
            ))

            XCTAssertEqual(inserted.currentDirectory, fallbackCwd)
            XCTAssertEqual(inserted.surfaceTabBarDirectory, fallbackCwd)
        }
    }

    func testDetachedWorkspaceTransferDirectoryWinsWhenInheritanceIsDisabled() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(false) {
            let sourceCwd = "/tmp/cmux-source-\(UUID().uuidString)"
            let transferCwd = "/tmp/cmux-detached-\(UUID().uuidString)"
            let manager = TabManager(
                initialWorkingDirectory: sourceCwd,
                autoWelcomeIfNeeded: false
            )
            let source = try XCTUnwrap(manager.selectedWorkspace)
            let detached = makeDetachedWorkspaceTestTransfer(
                sourceWorkspaceId: source.id,
                directory: transferCwd
            )

            let inserted = try XCTUnwrap(manager.addWorkspace(
                fromDetachedSurface: detached,
                select: false
            ))

            XCTAssertEqual(inserted.currentDirectory, transferCwd)
            XCTAssertEqual(inserted.surfaceTabBarDirectory, transferCwd)
        }
    }

    func testDetachedWorkspaceDoesNotPersistProcessDetectedResumeBinding() throws {
        let manager = TabManager(
            initialWorkingDirectory: "/tmp/cmux-source-\(UUID().uuidString)",
            autoWelcomeIfNeeded: false
        )
        let source = try XCTUnwrap(manager.selectedWorkspace)
        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t work",
            cwd: "/tmp/cmux-source",
            checkpointId: "work",
            source: "process-detected",
            updatedAt: 1_777_777_777
        )
        let detached = makeDetachedWorkspaceTestTransfer(
            sourceWorkspaceId: source.id,
            resumeBinding: binding
        )

        let inserted = try XCTUnwrap(manager.addWorkspace(
            fromDetachedSurface: detached,
            select: false
        ))

        XCTAssertNil(inserted.surfaceResumeBinding(panelId: detached.panelId))
    }

    private func withWorkspaceWorkingDirectoryInheritanceSetting(
        _ value: Bool?,
        _ body: () throws -> Void
    ) rethrows {
        let defaults = UserDefaults.standard
        let key = SettingCatalog().app.workspaceInheritWorkingDirectory.userDefaultsKey
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }

        try body()
    }

    private func makeDetachedWorkspaceTestTransfer(
        sourceWorkspaceId: UUID,
        directory: String? = nil,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil
    ) -> Workspace.DetachedSurfaceTransfer {
        let panel = DetachedWorkspaceTestPanel()
        return Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            panelId: panel.id,
            panel: panel,
            title: panel.displayTitle,
            icon: panel.displayIcon,
            iconImageData: nil,
            kind: "terminal",
            isLoading: false,
            isPinned: false,
            directory: directory,
            ttyName: nil,
            cachedTitle: nil,
            customTitle: nil,
            customTitleSource: nil,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: nil,
            restorableAgentResumeState: nil,
            resumeBinding: resumeBinding,
            agentRuntime: nil,
            isRemoteTerminal: false,
            remoteRelayPort: nil,
            remotePTYSessionID: nil,
            remoteCleanupConfiguration: nil
        )
    }
}


@MainActor
final class WorkspaceCreationPlacementTests: XCTestCase {
    private final class SnapshotMutatingTabManager: TabManager {
        var afterCaptureWorkspaceCreationSnapshot: (() -> Void)?
        var beforeCreateWorkspace: (() -> Void)?

        override func didCaptureWorkspaceCreationSnapshot() {
            afterCaptureWorkspaceCreationSnapshot?()
        }

        override func makeWorkspaceForCreation(
            title: String,
            workingDirectory: String?,
            portOrdinal: Int,
            configTemplate: CmuxSurfaceConfigTemplate?,
            initialSurface: NewWorkspaceInitialSurface,
            initialTerminalCommand: String?,
            initialTerminalInput: String?,
            initialTerminalEnvironment: [String: String],
            workspaceEnvironment: [String: String]
        ) -> Workspace {
            beforeCreateWorkspace?()
            return super.makeWorkspaceForCreation(
                title: title,
                workingDirectory: workingDirectory,
                portOrdinal: portOrdinal,
                configTemplate: configTemplate,
                initialSurface: initialSurface,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalInput: initialTerminalInput,
                initialTerminalEnvironment: initialTerminalEnvironment,
                workspaceEnvironment: workspaceEnvironment
            )
        }
    }

    func testAddWorkspaceDefaultPlacementMatchesCurrentSetting() {
        let currentPlacement = UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().app.newWorkspacePlacement)

        let defaultManager = makeManagerWithThreeWorkspaces()
        let defaultBaselineOrder = defaultManager.tabs.map(\.id)
        let defaultInserted = defaultManager.addWorkspace()
        guard let defaultInsertedIndex = defaultManager.tabs.firstIndex(where: { $0.id == defaultInserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }
        XCTAssertEqual(defaultManager.tabs.map(\.id).filter { $0 != defaultInserted.id }, defaultBaselineOrder)

        let explicitManager = makeManagerWithThreeWorkspaces()
        let explicitBaselineOrder = explicitManager.tabs.map(\.id)
        let explicitInserted = explicitManager.addWorkspace(placementOverride: currentPlacement)
        guard let explicitInsertedIndex = explicitManager.tabs.firstIndex(where: { $0.id == explicitInserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }
        XCTAssertEqual(explicitManager.tabs.map(\.id).filter { $0 != explicitInserted.id }, explicitBaselineOrder)
        XCTAssertEqual(defaultInsertedIndex, explicitInsertedIndex)
    }

    func testAddWorkspaceEndOverrideAlwaysAppends() {
        let manager = makeManagerWithThreeWorkspaces()
        let baselineCount = manager.tabs.count
        guard baselineCount >= 3 else {
            XCTFail("Expected at least three workspaces for placement regression test")
            return
        }

        let inserted = manager.addWorkspace(placementOverride: .end)
        guard let insertedIndex = manager.tabs.firstIndex(where: { $0.id == inserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }

        XCTAssertEqual(insertedIndex, baselineCount)
    }

    func testAddWorkspaceInIMessageModeInsertsAtTopOfUnpinnedSegment() {
        let defaults = UserDefaults.standard
        let placementKey = SettingCatalog().app.newWorkspacePlacement.userDefaultsKey
        let iMessageModeKey = IMessageModeSettings.key
        let previousPlacement = defaults.object(forKey: placementKey)
        let previousIMessageMode = defaults.object(forKey: iMessageModeKey)
        defer {
            if let previousPlacement {
                defaults.set(previousPlacement, forKey: placementKey)
            } else {
                defaults.removeObject(forKey: placementKey)
            }
            if let previousIMessageMode {
                defaults.set(previousIMessageMode, forKey: iMessageModeKey)
            } else {
                defaults.removeObject(forKey: iMessageModeKey)
            }
        }

        defaults.set(WorkspacePlacement.end.rawValue, forKey: placementKey)
        defaults.set(true, forKey: iMessageModeKey)

        let manager = TabManager()
        guard let pinned = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }
        manager.setPinned(pinned, pinned: true)
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let third = manager.addWorkspace(select: false, placementOverride: .end)
        manager.selectWorkspace(third)

        let inserted = manager.addWorkspace()

        XCTAssertEqual(manager.tabs.map(\.id), [pinned.id, inserted.id, second.id, third.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceAfterCurrentOverrideAppendsAfterLastSelectedWorkspace() {
        let manager = TabManager()
        guard !manager.tabs.isEmpty else {
            XCTFail("Expected TabManager to initialise with at least one workspace")
            return
        }
        _ = manager.addWorkspace()
        _ = manager.addWorkspace()
        let fourth = manager.addWorkspace()
        let baselineOrder = manager.tabs.map(\.id)

        manager.selectWorkspace(fourth)
        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id).filter { $0 != inserted.id }, baselineOrder)
        XCTAssertEqual(manager.tabs.last?.id, inserted.id)
    }

    func testAddWorkspaceAfterCurrentUsesPrecreationSnapshotWhenSelectionMutatesDuringBootstrap() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        manager.setPinned(first, pinned: true)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        let baselineOrder = manager.tabs.map(\.id)
        manager.beforeCreateWorkspace = {
            manager.selectWorkspace(first)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id).filter { $0 != inserted.id }, baselineOrder)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, third.id, inserted.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceAfterCurrentDoesNotReinsertClosedWorkspaceCapturedInSnapshot() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            manager.closeWorkspace(second)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id, third.id, inserted.id])
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == second.id }))
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceSurvivesSelectedWorkspaceClosingAfterSnapshot() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            manager.closeWorkspace(third)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, inserted.id])
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == third.id }))
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceSurvivesMidCreationClose() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let closingWorkspace = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        let closingWorkspaceId = closingWorkspace.id
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, closingWorkspaceId, third.id])

        manager.afterCaptureWorkspaceCreationSnapshot = {
            guard let liveWorkspace = manager.tabs.first(where: { $0.id == closingWorkspaceId }) else {
                XCTFail("Expected captured workspace to still be present when closing after snapshot")
                return
            }
            manager.closeWorkspace(liveWorkspace)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == closingWorkspaceId }))
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, third.id, inserted.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceAfterCurrentUsesSnapshotPinnedStateWhenPinningMutatesAfterSnapshot() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        manager.setPinned(first, pinned: true)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(first)
        let baselineOrder = manager.tabs.map(\.id)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            manager.setPinned(first, pinned: false)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id).filter { $0 != inserted.id }, baselineOrder)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, inserted.id, second.id, third.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceAfterCurrentFollowsLiveReorderUsingSnapshotTabValues() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(second)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            XCTAssertTrue(
                manager.reorderWorkspace(tabId: third.id, toIndex: 0),
                "Expected to reorder live workspaces after the snapshot is captured"
            )
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(
            manager.tabs.map(\.id).filter { $0 != inserted.id },
            [third.id, first.id, second.id]
        )
        XCTAssertEqual(manager.tabs.map(\.id), [third.id, first.id, second.id, inserted.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    private func makeManagerWithThreeWorkspaces() -> TabManager {
        let manager = TabManager()
        _ = manager.addWorkspace()
        _ = manager.addWorkspace()
        if let first = manager.tabs.first {
            manager.selectWorkspace(first)
        }
        return manager
    }
}

@MainActor
final class WorkspaceCreationConfigSanitizationTests: XCTestCase {
    private final class UnsafeConfigSnapshotTabManager: TabManager {
        private var injectedConfig: CmuxSurfaceConfigTemplate?
        var capturedConfigTemplate: CmuxSurfaceConfigTemplate?

        func installInjectedConfig(fontSize: Float) {
            var config = CmuxSurfaceConfigTemplate()
            config.fontSize = fontSize
            config.workingDirectory = "/tmp/cmux-workspace-snapshot"
            config.command = "echo snapshot"
            config.environmentVariables = ["CMUX_INHERITED_ENV": "1"]
            injectedConfig = config
        }

        override func inheritedTerminalConfigForNewWorkspace(
            workspace: Workspace?
        ) -> CmuxSurfaceConfigTemplate? {
            injectedConfig ?? super.inheritedTerminalConfigForNewWorkspace(workspace: workspace)
        }

        override func makeWorkspaceForCreation(
            title: String,
            workingDirectory: String?,
            portOrdinal: Int,
            configTemplate: CmuxSurfaceConfigTemplate?,
            initialSurface: NewWorkspaceInitialSurface,
            initialTerminalCommand: String?,
            initialTerminalInput: String?,
            initialTerminalEnvironment: [String: String],
            workspaceEnvironment: [String: String]
        ) -> Workspace {
            capturedConfigTemplate = configTemplate
            return super.makeWorkspaceForCreation(
                title: title,
                workingDirectory: workingDirectory,
                portOrdinal: portOrdinal,
                configTemplate: configTemplate,
                initialSurface: initialSurface,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalInput: initialTerminalInput,
                initialTerminalEnvironment: initialTerminalEnvironment,
                workspaceEnvironment: workspaceEnvironment
            )
        }
    }

    func testAddWorkspacePassesSanitizedInheritedConfigTemplate() {
        let manager = UnsafeConfigSnapshotTabManager()
        manager.installInjectedConfig(fontSize: 19)

        _ = manager.addWorkspace()

        guard let capturedConfig = manager.capturedConfigTemplate else {
            XCTFail("Expected captured config template for new workspace")
            return
        }

        XCTAssertEqual(capturedConfig.fontSize, 19, accuracy: 0.001)
        XCTAssertNil(capturedConfig.workingDirectory)
        XCTAssertNil(capturedConfig.command)
        XCTAssertTrue(capturedConfig.environmentVariables.isEmpty)
    }
}

@MainActor
final class NewBrowserWorkspaceCreationTests: XCTestCase {
    func testNewBrowserWorkspaceShortcutDefaultsAndMetadata() {
        XCTAssertEqual(KeyboardShortcutSettings.Action.newBrowserWorkspace.label, "New Browser Workspace")
        XCTAssertEqual(KeyboardShortcutSettings.Action.newBrowserWorkspace.defaultsKey, "shortcut.newBrowserWorkspace")
        XCTAssertTrue(KeyboardShortcutSettings.publicShortcutActions.contains(.newBrowserWorkspace))

        let shortcut = KeyboardShortcutSettings.Action.newBrowserWorkspace.defaultShortcut
        XCTAssertEqual(shortcut.key, "n")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.option)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.control)
    }

    func testNewBrowserWorkspaceDefaultDoesNotCollideWithOtherDefaults() {
        let newDefault = KeyboardShortcutSettings.Action.newBrowserWorkspace.defaultShortcut
        for action in KeyboardShortcutSettings.Action.allCases where action != .newBrowserWorkspace {
            let other = action.defaultShortcut
            guard !other.isUnbound else { continue }
            XCTAssertFalse(
                other.key == newDefault.key
                    && other.command == newDefault.command
                    && other.shift == newDefault.shift
                    && other.option == newDefault.option
                    && other.control == newDefault.control,
                "Option+Cmd+N default collides with \(action.rawValue)"
            )
        }
    }

    func testAddWorkspaceWithBrowserInitialSurfaceBootsBrowserPane() {
        let manager = TabManager()
        let baselineOrder = manager.tabs.map(\.id)

        let workspace = manager.addWorkspace(initialSurface: .browser)

        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertEqual(manager.tabs.map(\.id).filter { $0 != workspace.id }, baselineOrder)

        XCTAssertEqual(workspace.panels.count, 1)
        guard let browserPanel = workspace.panels.values.first as? BrowserPanel else {
            XCTFail("Expected the initial surface to be a browser pane")
            return
        }
        XCTAssertNil(workspace.focusedTerminalPanel)
        XCTAssertNil(browserPanel.currentURL, "Browser should boot in its default new-tab state")
        XCTAssertNotNil(
            browserPanel.pendingAddressBarFocusRequestId,
            "Browser workspace should request address-bar focus for first activation"
        )

        let tabIds = workspace.bonsplitController.allTabIds
        XCTAssertEqual(tabIds.count, 1)
        XCTAssertEqual(
            tabIds.first.flatMap { workspace.bonsplitController.tab($0)?.kind },
            SurfaceKind.browser.rawValue
        )
        XCTAssertEqual(workspace.title, String(localized: "browser.newTab", defaultValue: "New tab"))
    }

    func testBrowserInitialSurfacePlacementMatchesTerminalPlacement() {
        let terminalManager = makeManagerWithThreeWorkspaces()
        let terminalInserted = terminalManager.addWorkspace()
        let terminalIndex = terminalManager.tabs.firstIndex { $0.id == terminalInserted.id }

        let browserManager = makeManagerWithThreeWorkspaces()
        let browserInserted = browserManager.addWorkspace(initialSurface: .browser)
        let browserIndex = browserManager.tabs.firstIndex { $0.id == browserInserted.id }

        XCTAssertNotNil(terminalIndex)
        XCTAssertEqual(
            browserIndex,
            terminalIndex,
            "Browser workspaces must follow New Workspace placement semantics"
        )
    }

    private func makeManagerWithThreeWorkspaces() -> TabManager {
        let manager = TabManager()
        _ = manager.addWorkspace()
        _ = manager.addWorkspace()
        if let first = manager.tabs.first {
            manager.selectWorkspace(first)
        }
        return manager
    }
}


final class WorkspaceTabColorSettingsTests: XCTestCase {
    func testNormalizedHexAcceptsAndNormalizesValidInput() {
        XCTAssertEqual(WorkspaceTabColorSettings.normalizedHex("#abc123"), "#ABC123")
        XCTAssertEqual(WorkspaceTabColorSettings.normalizedHex("  aBcDeF "), "#ABCDEF")
        XCTAssertNil(WorkspaceTabColorSettings.normalizedHex("#1234"))
        XCTAssertNil(WorkspaceTabColorSettings.normalizedHex("#GG1234"))
    }

    func testBuiltInPaletteMatchesOriginalPRPalette() {
        let palette = WorkspaceTabColorSettings.defaultPalette
        XCTAssertEqual(palette.count, 16)
        XCTAssertEqual(palette.first?.name, "Red")
        XCTAssertEqual(palette.first?.hex, "#C0392B")
        XCTAssertEqual(palette.last?.name, "Charcoal")
        XCTAssertFalse(palette.contains(where: { $0.name == "Gold" }))
    }

    func testPaletteFallsBackToBuiltInDefaultsWhenUnset() {
        let suiteName = "WorkspaceTabColorSettingsTests.BuiltInPalette.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(WorkspaceTabColorSettings.palette(defaults: defaults), WorkspaceTabColorSettings.defaultPalette)
    }

    func testSetColorRoundTripFallsBackWhenResetToBase() {
        let suiteName = "WorkspaceTabColorSettingsTests.SetColor.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = WorkspaceTabColorSettings.defaultPalette[0]
        XCTAssertEqual(
            WorkspaceTabColorSettings.currentColorHex(named: first.name, defaults: defaults),
            first.hex
        )

        WorkspaceTabColorSettings.setColor(named: first.name, hex: "#00aa33", defaults: defaults)
        XCTAssertEqual(
            WorkspaceTabColorSettings.currentColorHex(named: first.name, defaults: defaults),
            "#00AA33"
        )
        XCTAssertNotNil(defaults.dictionary(forKey: WorkspaceTabColorSettings.paletteKey))

        WorkspaceTabColorSettings.setColor(named: first.name, hex: first.hex, defaults: defaults)
        XCTAssertEqual(
            WorkspaceTabColorSettings.currentColorHex(named: first.name, defaults: defaults),
            first.hex
        )
        XCTAssertNil(defaults.object(forKey: WorkspaceTabColorSettings.paletteKey))
    }

    func testAddCustomColorCreatesNamedEntriesAndDeduplicatesByHex() {
        let suiteName = "WorkspaceTabColorSettingsTests.NamedCustomColors.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor(" #00aa33 ", defaults: defaults),
            "#00AA33"
        )
        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor("#112233", defaults: defaults),
            "#112233"
        )
        XCTAssertEqual(
            WorkspaceTabColorSettings.addCustomColor("#00AA33", defaults: defaults),
            "#00AA33"
        )
        XCTAssertNil(WorkspaceTabColorSettings.addCustomColor("nope", defaults: defaults))

        let customEntries = WorkspaceTabColorSettings.customPaletteEntries(defaults: defaults)
        XCTAssertEqual(customEntries.map(\.name), ["Custom 1", "Custom 2"])
        XCTAssertEqual(customEntries.map(\.hex), ["#00AA33", "#112233"])
    }

    func testPaletteDictionaryCanRemoveBuiltInEntriesAndAddNamedOnes() {
        let suiteName = "WorkspaceTabColorSettingsTests.DictionaryPalette.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var palette = Dictionary(uniqueKeysWithValues: WorkspaceTabColorSettings.defaultPalette.map { ($0.name, $0.hex) })
        palette.removeValue(forKey: "Red")
        palette["Neon Mint"] = "#00F5D4"
        WorkspaceTabColorSettings.persistPaletteMap(palette, defaults: defaults)

        let resolved = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertFalse(resolved.contains(where: { $0.name == "Red" }))
        XCTAssertEqual(resolved.first?.name, "Crimson")
        XCTAssertEqual(resolved.last?.name, "Neon Mint")
        XCTAssertEqual(resolved.last?.hex, "#00F5D4")
    }

    func testLegacyKeysStillResolveIntoEffectivePalette() {
        let suiteName = "WorkspaceTabColorSettingsTests.LegacyKeys.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["Blue": "#010203"], forKey: "workspaceTabColor.defaultOverrides")
        defaults.set(["#778899"], forKey: "workspaceTabColor.customColors")

        let resolved = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertEqual(
            resolved.first(where: { $0.name == "Blue" })?.hex,
            "#010203"
        )
        XCTAssertEqual(
            resolved.first(where: { $0.name == "Custom 1" })?.hex,
            "#778899"
        )
    }

    func testResetClearsNewAndLegacyStorage() {
        let suiteName = "WorkspaceTabColorSettingsTests.Reset.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        WorkspaceTabColorSettings.persistPaletteMap(["Neon Mint": "#00F5D4"], defaults: defaults)
        defaults.set(["Blue": "#010203"], forKey: "workspaceTabColor.defaultOverrides")
        defaults.set(["#778899"], forKey: "workspaceTabColor.customColors")

        WorkspaceTabColorSettings.reset(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: WorkspaceTabColorSettings.paletteKey))
        XCTAssertNil(defaults.object(forKey: "workspaceTabColor.defaultOverrides"))
        XCTAssertNil(defaults.object(forKey: "workspaceTabColor.customColors"))
        XCTAssertEqual(WorkspaceTabColorSettings.palette(defaults: defaults), WorkspaceTabColorSettings.defaultPalette)
    }

    func testDisplayColorLightModeKeepsOriginalHex() {
        let originalHex = "#1A5276"
        let rendered = WorkspaceTabColorSettings.displayNSColor(
            hex: originalHex,
            colorScheme: .light
        )

        XCTAssertEqual(rendered?.hexString(), originalHex)
    }

    func testDisplayColorDarkModeBrightensColor() {
        let originalHex = "#1A5276"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .dark
              ) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertNotEqual(rendered.hexString(), originalHex)
        XCTAssertGreaterThan(rendered.luminance, base.luminance)
    }

    func testDisplayColorDarkModeKeepsGrayscaleNeutral() {
        let originalHex = "#808080"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .dark
              ),
              let renderedSRGB = rendered.usingColorSpace(.sRGB) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertGreaterThan(rendered.luminance, base.luminance)
        XCTAssertLessThan(abs(renderedSRGB.redComponent - renderedSRGB.greenComponent), 0.003)
        XCTAssertLessThan(abs(renderedSRGB.greenComponent - renderedSRGB.blueComponent), 0.003)
    }

    func testDisplayColorForceBrightensInLightMode() {
        let originalHex = "#1A5276"
        guard let base = NSColor(hex: originalHex),
              let rendered = WorkspaceTabColorSettings.displayNSColor(
                  hex: originalHex,
                  colorScheme: .light,
                  forceBright: true
              ) else {
            XCTFail("Expected valid color conversion")
            return
        }

        XCTAssertNotEqual(rendered.hexString(), originalHex)
        XCTAssertGreaterThan(rendered.luminance, base.luminance)
    }
}


final class WorkspaceAutoReorderSettingsTests: XCTestCase {
    func testDefaultIsEnabled() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().app.reorderOnNotification))
    }

    func testDisabledWhenSetToFalse() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Disabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: SettingCatalog().app.reorderOnNotification.userDefaultsKey)
        XCTAssertFalse(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().app.reorderOnNotification))
    }

    func testEnabledWhenSetToTrue() {
        let suiteName = "WorkspaceAutoReorderSettingsTests.Enabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: SettingCatalog().app.reorderOnNotification.userDefaultsKey)
        XCTAssertTrue(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().app.reorderOnNotification))
    }
}


final class SidebarWorkspaceDetailSettingsTests: XCTestCase {
    func testDefaultPreferencesWhenUnset() {
        let suiteName = "SidebarWorkspaceDetailSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.hideAllDetails))
        XCTAssertTrue(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.showWorkspaceDescription))
        XCTAssertTrue(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.showNotificationMessage))
        XCTAssertTrue(
            SidebarWorkspaceDetailVisibility(
                showWorkspaceDescription: UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.showWorkspaceDescription),
                showNotificationMessage: true,
                hideAllDetails: UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.hideAllDetails)
            ).showsWorkspaceDescription
        )
        XCTAssertTrue(
            SidebarWorkspaceDetailVisibility(
                showWorkspaceDescription: true,
                showNotificationMessage: UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.showNotificationMessage),
                hideAllDetails: UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.hideAllDetails)
            ).showsNotificationMessage
        )
    }

    func testStoredPreferencesOverrideDefaults() {
        let suiteName = "SidebarWorkspaceDetailSettingsTests.Stored.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: SettingCatalog().sidebar.hideAllDetails.userDefaultsKey)
        defaults.set(false, forKey: SettingCatalog().sidebar.showWorkspaceDescription.userDefaultsKey)
        defaults.set(false, forKey: SettingCatalog().sidebar.showNotificationMessage.userDefaultsKey)

        XCTAssertTrue(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.hideAllDetails))
        XCTAssertFalse(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.showWorkspaceDescription))
        XCTAssertFalse(UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.showNotificationMessage))
        XCTAssertFalse(
            SidebarWorkspaceDetailVisibility(
                showWorkspaceDescription: UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.showWorkspaceDescription),
                showNotificationMessage: true,
                hideAllDetails: false
            ).showsWorkspaceDescription
        )
        XCTAssertFalse(
            SidebarWorkspaceDetailVisibility(
                showWorkspaceDescription: true,
                showNotificationMessage: true,
                hideAllDetails: UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.hideAllDetails)
            ).showsWorkspaceDescription
        )
        XCTAssertFalse(
            SidebarWorkspaceDetailVisibility(
                showWorkspaceDescription: true,
                showNotificationMessage: UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.showNotificationMessage),
                hideAllDetails: false
            ).showsNotificationMessage
        )
        XCTAssertFalse(
            SidebarWorkspaceDetailVisibility(
                showWorkspaceDescription: true,
                showNotificationMessage: true,
                hideAllDetails: UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().sidebar.hideAllDetails)
            ).showsNotificationMessage
        )
    }
}


final class SidebarWorkspaceAuxiliaryDetailVisibilityTests: XCTestCase {
    func testResolvedVisibilityPreservesPerRowTogglesWhenDetailsAreShown() {
        XCTAssertEqual(
            SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
                showMetadata: true,
                showLog: false,
                showProgress: true,
                showBranchDirectory: false,
                showPullRequests: true,
                showPorts: false,
                hideAllDetails: false
            ),
            SidebarWorkspaceAuxiliaryDetailVisibility(
                showsMetadata: true,
                showsLog: false,
                showsProgress: true,
                showsBranchDirectory: false,
                showsPullRequests: true,
                showsPorts: false
            )
        )
    }

    func testResolvedVisibilityHidesAllAuxiliaryRowsWhenDetailsAreHidden() {
        XCTAssertEqual(
            SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
                showMetadata: true,
                showLog: true,
                showProgress: true,
                showBranchDirectory: true,
                showPullRequests: true,
                showPorts: true,
                hideAllDetails: true
            ),
            .hidden
        )
    }
}


final class SidebarWorkspaceSelectionSyncPolicyTests: XCTestCase {
    @MainActor
    func testReconciledSelectionPreservesMultiSelectionAfterReorder() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()
        let previousSelection: Set<UUID> = [second, third]

        let result = SidebarWorkspaceSelectionSyncPolicy().reconciledSelection(
            previousSelectionIds: previousSelection,
            liveWorkspaceIds: [first, third, fourth, second],
            fallbackSelectedWorkspaceId: second
        )

        XCTAssertEqual(result, previousSelection)
        XCTAssertEqual(
            SidebarWorkspaceSelectionSyncPolicy().anchorIndex(
                preferredWorkspaceId: second,
                selectedWorkspaceIds: result,
                liveWorkspaceIds: [first, third, fourth, second]
            ),
            3
        )
    }

    @MainActor
    func testReconciledSelectionFallsBackToActiveWorkspaceWhenPreviousSelectionIsGone() {
        let first = UUID()
        let second = UUID()
        let removed = UUID()

        let result = SidebarWorkspaceSelectionSyncPolicy().reconciledSelection(
            previousSelectionIds: [removed],
            liveWorkspaceIds: [first, second],
            fallbackSelectedWorkspaceId: second
        )

        XCTAssertEqual(result, [second])
    }
}


final class WorkspaceReorderTests: XCTestCase {
    @MainActor
    func testReorderWorkspacePostsMovedWorkspaceId() {
        let manager = TabManager()
        let second = manager.addWorkspace()
        _ = manager.addWorkspace()
        var observedMovedIds: [UUID] = []
        let token = NotificationCenter.default.addObserver(
            forName: WorkspaceOrderDidChangeEvent.notificationName,
            object: manager,
            queue: nil
        ) { notification in
            observedMovedIds = WorkspaceOrderDidChangeEvent(notification)?.movedWorkspaceIds ?? []
        }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertTrue(manager.reorderWorkspace(tabId: second.id, toIndex: 0))

        XCTAssertEqual(observedMovedIds, [second.id])
    }

    @MainActor
    func testMoveTabsToTopPostsMovedWorkspaceIds() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        var observedMovedIds: [UUID] = []
        let token = NotificationCenter.default.addObserver(
            forName: WorkspaceOrderDidChangeEvent.notificationName,
            object: manager,
            queue: nil
        ) { notification in
            observedMovedIds = WorkspaceOrderDidChangeEvent(notification)?.movedWorkspaceIds ?? []
        }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.moveTabsToTop([third.id, second.id])

        XCTAssertEqual(manager.tabs.map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(observedMovedIds, [second.id, third.id])
    }

    @MainActor
    func testMoveTabsToTopSkipsNotificationWhenOrderDoesNotChange() {
        let manager = TabManager()
        let first = manager.tabs[0]
        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: WorkspaceOrderDidChangeEvent.notificationName,
            object: manager,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.moveTabsToTop([first.id])

        XCTAssertEqual(manager.tabs.map(\.id), [first.id])
        XCTAssertEqual(notificationCount, 0)
    }

    @MainActor
    func testMoveTabToTopPostsMovedWorkspaceIdWhenOrderChanges() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        var observedMovedIds: [UUID] = []
        let token = NotificationCenter.default.addObserver(
            forName: WorkspaceOrderDidChangeEvent.notificationName,
            object: manager,
            queue: nil
        ) { notification in
            observedMovedIds = WorkspaceOrderDidChangeEvent(notification)?.movedWorkspaceIds ?? []
        }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.moveTabToTop(second.id)

        XCTAssertEqual(manager.tabs.map(\.id), [second.id, first.id])
        XCTAssertEqual(observedMovedIds, [second.id])
    }

    @MainActor
    func testMoveTabToTopPublishesWorkspaceReorderedEvent() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        CmuxEventBus.shared.resetForTesting()

        manager.moveTabToTop(second.id)

        let event = try XCTUnwrap(CmuxEventBus.shared.retainedSnapshot().last)
        XCTAssertEqual(event["name"] as? String, "workspace.reordered")
        XCTAssertEqual(event["source"] as? String, "workspace.lifecycle")
        XCTAssertEqual(event["workspace_id"] as? String, second.id.uuidString)
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(
            payload["workspace_ids"] as? [String],
            [second.id.uuidString, first.id.uuidString]
        )
        XCTAssertEqual(payload["moved_workspace_ids"] as? [String], [second.id.uuidString])
        XCTAssertEqual(payload["pinned_workspace_ids"] as? [String], [])
    }

    @MainActor
    func testSetPinnedPublishesWorkspaceReorderedEventWithPinnedState() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        CmuxEventBus.shared.resetForTesting()

        manager.setPinned(second, pinned: true)

        let event = try XCTUnwrap(CmuxEventBus.shared.retainedSnapshot().last)
        XCTAssertEqual(event["name"] as? String, "workspace.reordered")
        XCTAssertEqual(event["source"] as? String, "workspace.lifecycle")
        XCTAssertEqual(event["workspace_id"] as? String, second.id.uuidString)
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(
            payload["workspace_ids"] as? [String],
            [second.id.uuidString, first.id.uuidString]
        )
        XCTAssertEqual(payload["moved_workspace_ids"] as? [String], [second.id.uuidString])
        XCTAssertEqual(payload["pinned_workspace_ids"] as? [String], [second.id.uuidString])
    }

    @MainActor
    func testMoveTabToTopSkipsNotificationWhenUnpinnedAlreadyFirstBelowPinnedWorkspaces() {
        let manager = TabManager()
        let pinned = manager.tabs[0]
        manager.setPinned(pinned, pinned: true)
        let firstUnpinned = manager.addWorkspace()
        _ = manager.addWorkspace()
        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: WorkspaceOrderDidChangeEvent.notificationName,
            object: manager,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.moveTabToTop(firstUnpinned.id)

        XCTAssertEqual(manager.tabs.map(\.id).prefix(2), [pinned.id, firstUnpinned.id])
        XCTAssertEqual(notificationCount, 0)
    }

    @MainActor
    func testReorderWorkspaceMovesWorkspaceToRequestedIndex() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        manager.selectWorkspace(second)
        XCTAssertEqual(manager.selectedTabId, second.id)

        XCTAssertTrue(manager.reorderWorkspace(tabId: second.id, toIndex: 0))
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, first.id, third.id])
        XCTAssertEqual(manager.selectedTabId, second.id)
    }

    @MainActor
    func testReorderWorkspaceClampsOutOfRangeTargetIndex() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: first.id, toIndex: 999))
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, third.id, first.id])
    }

    @MainActor
    func testReorderWorkspaceReturnsFalseForUnknownWorkspace() {
        let manager = TabManager()
        XCTAssertFalse(manager.reorderWorkspace(tabId: UUID(), toIndex: 0))
    }

    @MainActor
    func testReorderWorkspaceKeepsUnpinnedWorkspaceBelowPinnedSegment() {
        let manager = TabManager()
        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let unpinned = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: unpinned.id, toIndex: 0))
        XCTAssertEqual(manager.tabs.map(\.id), [firstPinned.id, secondPinned.id, unpinned.id])
    }

    @MainActor
    func testReorderWorkspaceKeepsPinnedWorkspaceInsidePinnedSegment() {
        let manager = TabManager()
        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let unpinned = manager.addWorkspace()

        XCTAssertTrue(manager.reorderWorkspace(tabId: firstPinned.id, toIndex: 999))
        XCTAssertEqual(manager.tabs.map(\.id), [secondPinned.id, firstPinned.id, unpinned.id])
    }

    @MainActor
    func testBatchReorderAppliesFinalLeadingOrderAtomically() throws {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        let fourth = manager.addWorkspace()
        var observedMovedIds: [UUID] = []
        let token = NotificationCenter.default.addObserver(
            forName: WorkspaceOrderDidChangeEvent.notificationName,
            object: manager,
            queue: nil
        ) { notification in
            observedMovedIds = WorkspaceOrderDidChangeEvent(notification)?.movedWorkspaceIds ?? []
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let result = manager.reorderWorkspaces(orderedWorkspaceIds: [third.id, first.id])
        let plan = try result.get()

        XCTAssertEqual(manager.tabs.map(\.id), [third.id, first.id, second.id, fourth.id])
        XCTAssertEqual(
            plan,
            [
                WorkspaceReorderPlanItem(workspaceId: third.id, fromIndex: 2, toIndex: 0),
                WorkspaceReorderPlanItem(workspaceId: first.id, fromIndex: 0, toIndex: 1)
            ]
        )
        XCTAssertEqual(observedMovedIds, [third.id, first.id])
    }

    @MainActor
    func testBatchReorderRejectsUnknownWorkspaceWithoutPartialMutation() {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        let originalOrder = manager.tabs.map(\.id)
        let unknown = UUID()

        let result = manager.reorderWorkspaces(orderedWorkspaceIds: [third.id, unknown, first.id])

        XCTAssertEqual(result, .failure(.workspaceNotFound(unknown)))
        XCTAssertEqual(manager.tabs.map(\.id), originalOrder)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, third.id])
    }

    @MainActor
    func testBatchReorderDryRunReturnsPlanWithoutMutation() throws {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        let originalOrder = manager.tabs.map(\.id)

        let result = manager.reorderWorkspaces(orderedWorkspaceIds: [third.id, first.id], dryRun: true)
        let plan = try result.get()

        XCTAssertEqual(manager.tabs.map(\.id), originalOrder)
        XCTAssertEqual(
            plan,
            [
                WorkspaceReorderPlanItem(workspaceId: third.id, fromIndex: 2, toIndex: 0),
                WorkspaceReorderPlanItem(workspaceId: first.id, fromIndex: 0, toIndex: 1)
            ]
        )
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, third.id])
    }

    @MainActor
    func testBatchReorderPreservesPinnedWorkspaceSegment() throws {
        let manager = TabManager()
        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let firstUnpinned = manager.addWorkspace()
        let secondUnpinned = manager.addWorkspace()

        let result = manager.reorderWorkspaces(orderedWorkspaceIds: [secondUnpinned.id, secondPinned.id])
        let plan = try result.get()

        XCTAssertEqual(
            manager.tabs.map(\.id),
            [secondPinned.id, firstPinned.id, secondUnpinned.id, firstUnpinned.id]
        )
        XCTAssertEqual(
            plan,
            [
                WorkspaceReorderPlanItem(workspaceId: secondUnpinned.id, fromIndex: 3, toIndex: 2),
                WorkspaceReorderPlanItem(workspaceId: secondPinned.id, fromIndex: 1, toIndex: 0)
            ]
        )
    }

    @MainActor
    func testDetachedWorkspaceInsertionOverrideClampsAfterPinnedSegment() {
        let manager = TabManager()
        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let source = manager.addWorkspace()
        manager.selectWorkspace(source)

        guard let panelId = source.focusedPanelId,
              let detached = source.detachSurface(panelId: panelId),
              let inserted = manager.addWorkspace(
                fromDetachedSurface: detached,
                insertionIndexOverride: 0
              ) else {
            XCTFail("Expected detached workspace insertion to succeed")
            return
        }

        XCTAssertEqual(manager.tabs.map(\.id), [firstPinned.id, secondPinned.id, inserted.id, source.id])
        XCTAssertFalse(inserted.isPinned)
    }
}

@MainActor
final class WorkspaceNotificationReorderTests: XCTestCase {
    func testNotificationAutoReorderDoesNotMovePinnedWorkspace() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let notificationStore = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let defaults = UserDefaults.standard
        let originalAutoReorderSetting = defaults.object(forKey: SettingCatalog().app.reorderOnNotification.userDefaultsKey)
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        notificationStore.replaceNotificationsForTesting([])
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = notificationStore
        defaults.set(true, forKey: SettingCatalog().app.reorderOnNotification.userDefaultsKey)
        AppFocusState.overrideIsFocused = false

        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalAutoReorderSetting {
                defaults.set(originalAutoReorderSetting, forKey: SettingCatalog().app.reorderOnNotification.userDefaultsKey)
            } else {
                defaults.removeObject(forKey: SettingCatalog().app.reorderOnNotification.userDefaultsKey)
            }
        }

        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let unpinned = manager.addWorkspace()
        let expectedOrder = [firstPinned.id, secondPinned.id, unpinned.id]

        notificationStore.addNotification(
            tabId: secondPinned.id,
            surfaceId: nil,
            title: "Build finished",
            subtitle: "",
            body: "Pinned workspaces should stay put"
        )

        XCTAssertEqual(manager.tabs.map(\.id), expectedOrder)
    }
}


@MainActor
final class WorkspaceTeardownTests: XCTestCase {
    func testTeardownAllPanelsClearsPanelMetadataCaches() {
        let workspace = Workspace()
        guard let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel in new workspace")
            return
        }

        workspace.setPanelCustomTitle(panelId: initialPanelId, title: "Initial custom title")
        workspace.setPanelPinned(panelId: initialPanelId, pinned: true)

        guard let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }

        workspace.setPanelCustomTitle(panelId: splitPanel.id, title: "Split custom title")
        workspace.setPanelPinned(panelId: splitPanel.id, pinned: true)
        workspace.markPanelUnread(initialPanelId)

        XCTAssertFalse(workspace.panels.isEmpty)
        XCTAssertFalse(workspace.panelTitles.isEmpty)
        XCTAssertFalse(workspace.panelCustomTitles.isEmpty)
        XCTAssertFalse(workspace.pinnedPanelIds.isEmpty)
        XCTAssertFalse(workspace.manualUnreadPanelIds.isEmpty)

        workspace.teardownAllPanels()

        XCTAssertTrue(workspace.panels.isEmpty)
        XCTAssertTrue(workspace.panelTitles.isEmpty)
        XCTAssertTrue(workspace.panelCustomTitles.isEmpty)
        XCTAssertTrue(workspace.pinnedPanelIds.isEmpty)
        XCTAssertTrue(workspace.manualUnreadPanelIds.isEmpty)
    }

    func testDisabledPortalRenderingDoesNotRestoreTerminalVisibility() throws {
#if DEBUG
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let terminalPanel = try XCTUnwrap(workspace.terminalPanel(for: panelId))

        terminalPanel.hostedView.setVisibleInUI(true)
        workspace.setPortalRenderingEnabled(false, reason: "test")
        XCTAssertFalse(terminalPanel.hostedView.debugPortalVisibleInUI)

        workspace.debugReconcileTerminalPortalVisibilityForTesting()
        XCTAssertFalse(terminalPanel.hostedView.debugPortalVisibleInUI)
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }
}


@MainActor
final class WorkspaceSplitWorkingDirectoryTests: XCTestCase {
    private func waitForCondition(
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.01,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    private func hostTerminalPanelInWindow(_ panel: TerminalPanel) throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let contentView = try XCTUnwrap(window.contentView, "Expected content view")

        let hostedView = panel.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            waitForCondition {
                panel.surface.surface != nil
            },
            "Expected runtime surface to materialize after hosting panel in a window"
        )
        return window
    }

    func testNewTerminalSplitFallsBackToRequestedWorkingDirectoryWhenReportedDirectoryIsStale() {
        let workspace = Workspace()
        guard let sourcePaneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected focused pane in new workspace")
            return
        }

        let staleCurrentDirectory = workspace.currentDirectory
        let requestedDirectory = "/tmp/cmux-requested-split-cwd-\(UUID().uuidString)"
        guard let sourcePanel = workspace.newTerminalSurface(
            inPane: sourcePaneId,
            focus: false,
            workingDirectory: requestedDirectory
        ) else {
            XCTFail("Expected source terminal panel to be created")
            return
        }

        XCTAssertEqual(sourcePanel.requestedWorkingDirectory, requestedDirectory)
        XCTAssertNil(
            workspace.panelDirectories[sourcePanel.id],
            "Expected requested cwd to exist before shell integration reports a live cwd"
        )
        XCTAssertEqual(
            workspace.currentDirectory,
            staleCurrentDirectory,
            "Expected focused workspace cwd to remain stale before panel directory updates"
        )

        guard let splitPanel = workspace.newTerminalSplit(
            from: sourcePanel.id,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected split terminal panel to be created")
            return
        }

        XCTAssertEqual(
            splitPanel.requestedWorkingDirectory,
            requestedDirectory,
            "Expected split to inherit the source terminal's requested cwd when no reported cwd exists yet"
        )
    }

    func testNewTerminalSplitSkipsFreedInheritedSurfacePointer() throws {
#if DEBUG
        let workspace = Workspace()
        guard let sourcePanelId = workspace.focusedPanelId,
              let sourcePanel = workspace.terminalPanel(for: sourcePanelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let window = try hostTerminalPanelInWindow(sourcePanel)
        defer { window.orderOut(nil) }

        XCTAssertNotNil(sourcePanel.surface.surface, "Expected runtime surface before forcing stale pointer")

        sourcePanel.surface.replaceSurfaceWithFreedPointerForTesting()
        XCTAssertNotNil(
            sourcePanel.surface.surface,
            "Expected Swift wrapper to remain non-nil while simulating a stale native surface"
        )

        let splitPanel = workspace.newTerminalSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            focus: false
        )

        XCTAssertNotNil(splitPanel, "Expected split creation to survive a stale inherited surface pointer")
        XCTAssertNil(sourcePanel.surface.surface, "Expected stale surface pointer to be quarantined")
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testNewTerminalSurfaceSkipsFreedInheritedSurfacePointer() throws {
#if DEBUG
        let workspace = Workspace()
        guard let sourcePanelId = workspace.focusedPanelId,
              let sourcePanel = workspace.terminalPanel(for: sourcePanelId),
              let sourcePaneId = workspace.paneId(forPanelId: sourcePanelId) else {
            XCTFail("Expected focused terminal panel and pane")
            return
        }

        let window = try hostTerminalPanelInWindow(sourcePanel)
        defer { window.orderOut(nil) }

        XCTAssertNotNil(sourcePanel.surface.surface, "Expected runtime surface before forcing stale pointer")

        sourcePanel.surface.replaceSurfaceWithFreedPointerForTesting()
        XCTAssertNotNil(
            sourcePanel.surface.surface,
            "Expected Swift wrapper to remain non-nil while simulating a stale native surface"
        )

        let createdPanel = workspace.newTerminalSurface(
            inPane: sourcePaneId,
            focus: false
        )

        XCTAssertNotNil(createdPanel, "Expected terminal creation to survive a stale inherited surface pointer")
        XCTAssertNil(sourcePanel.surface.surface, "Expected stale surface pointer to be quarantined")
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }
}


@MainActor
final class WorkspaceTerminalFocusRecoveryTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    private func surfaceView(in hostedView: GhosttySurfaceScrollView) -> GhosttyNSView? {
        var stack: [NSView] = [hostedView]
        while let current = stack.popLast() {
            if let surfaceView = current as? GhosttyNSView {
                return surfaceView
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

    func testTerminalFirstResponderConvergesSplitActiveStateWhenSelectionAlreadyMatches() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        XCTAssertEqual(
            workspace.focusedPanelId,
            rightPanel.id,
            "Expected the new split panel to be selected before simulating stale focus state"
        )

        // Simulate the split-pane failure mode: Bonsplit already points at the right panel,
        // but the active terminal state is still stale on the left panel.
        leftPanel.surface.setFocus(true)
        leftPanel.hostedView.setActive(true)
        rightPanel.surface.setFocus(false)
        rightPanel.hostedView.setActive(false)

        workspace.focusPanel(rightPanel.id, trigger: .terminalFirstResponder)

        XCTAssertFalse(
            leftPanel.hostedView.debugRenderStats().isActive,
            "Expected stale left-pane active state to be cleared"
        )
        XCTAssertTrue(
            rightPanel.hostedView.debugRenderStats().isActive,
            "Expected terminal-first-responder recovery to reactivate the selected split pane"
        )
    }

    func testTerminalClickRecoversSplitActiveStateWhenFocusCallbackIsSuppressed() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }
        let window = makeWindow()
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        leftPanel.hostedView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
        rightPanel.hostedView.frame = NSRect(x: 180, y: 0, width: 180, height: 220)
        contentView.addSubview(leftPanel.hostedView)
        contentView.addSubview(rightPanel.hostedView)

        leftPanel.hostedView.setVisibleInUI(true)
        rightPanel.hostedView.setVisibleInUI(true)
        leftPanel.hostedView.setFocusHandler {
            workspace.focusPanel(leftPanel.id, trigger: .terminalFirstResponder)
        }
        rightPanel.hostedView.setFocusHandler {
            workspace.focusPanel(rightPanel.id, trigger: .terminalFirstResponder)
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(
            workspace.focusedPanelId,
            rightPanel.id,
            "Expected the clicked split pane to already be selected before simulating stale focus state"
        )

        // Simulate the ghost-terminal race: the right pane is selected in Bonsplit, but stale
        // active state remains on the left and the right pane's AppKit focus callback never fires
        // after split reparent/layout churn.
        leftPanel.surface.setFocus(true)
        leftPanel.hostedView.setActive(true)
        rightPanel.surface.setFocus(false)
        rightPanel.hostedView.setActive(false)
        rightPanel.hostedView.suppressReparentFocus()
#if DEBUG
        XCTAssertTrue(rightPanel.hostedView.debugIsSuppressingReparentFocusForTesting())
#endif

        guard let rightSurfaceView = surfaceView(in: rightPanel.hostedView) else {
            XCTFail("Expected right terminal surface view")
            return
        }

        let pointInWindow = rightSurfaceView.convert(NSPoint(x: 24, y: 24), to: nil)
        let event = makeMouseEvent(type: .leftMouseDown, location: pointInWindow, window: window)
        rightSurfaceView.mouseDown(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
#if DEBUG
        XCTAssertFalse(
            rightPanel.hostedView.debugIsSuppressingReparentFocusForTesting(),
            "Explicit pointer focus should clear reparent-only focus suppression"
        )
#endif

        XCTAssertFalse(
            leftPanel.hostedView.debugRenderStats().isActive,
            "Expected clicking the selected split pane to clear stale sibling active state even when AppKit focus callbacks are suppressed"
        )
        XCTAssertTrue(
            rightPanel.hostedView.debugRenderStats().isActive,
            "Expected clicking the selected split pane to reactivate terminal input when focus callbacks are suppressed"
        )
        XCTAssertTrue(
            rightPanel.hostedView.isSurfaceViewFirstResponder(),
            "Expected the clicked split pane to become first responder"
        )
    }

    func testClearSuppressReparentFocusReassertsGhosttyFocusForCurrentFirstResponder() throws {
#if DEBUG
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPanel = workspace.terminalPanel(for: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }
        workspace.focusPanel(leftPanel.id, trigger: .terminalFirstResponder)
        XCTAssertEqual(workspace.focusedPanelId, leftPanel.id)

        let window = makeWindow()
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        leftPanel.hostedView.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
        rightPanel.hostedView.frame = NSRect(x: 180, y: 0, width: 180, height: 220)
        contentView.addSubview(leftPanel.hostedView)
        contentView.addSubview(rightPanel.hostedView)

        leftPanel.hostedView.setVisibleInUI(true)
        rightPanel.hostedView.setVisibleInUI(true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let leftSurfaceView = surfaceView(in: leftPanel.hostedView) else {
            XCTFail("Expected left terminal surface view")
            return
        }

        window.makeFirstResponder(nil)
        leftPanel.surface.setFocus(false)
        rightPanel.surface.setFocus(true)
        leftPanel.hostedView.suppressReparentFocus()

        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(leftSurfaceView))
        XCTAssertTrue(leftPanel.hostedView.isSurfaceViewFirstResponder())
        XCTAssertTrue(leftPanel.hostedView.debugRenderStats().desiredFocus)
        XCTAssertTrue(leftPanel.hostedView.debugPortalVisibleInUI)

        XCTAssertFalse(
            leftPanel.surface.debugDesiredFocusState(),
            "Suppressed reparent focus should not immediately flip the Ghostty focus bit"
        )

        leftPanel.hostedView.clearSuppressReparentFocus()
        XCTAssertTrue(leftPanel.surface.debugDesiredFocusState())
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testLayoutFollowUpClearsPendingReparentSuppressionWithoutResponderEvent() throws {
#if DEBUG
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let panel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected initial terminal panel")
            return
        }

        workspace.debugBeginReparentFocusSuppressionForTesting(
            panel.hostedView,
            reason: "workspace.testReparentSuppression"
        )
        XCTAssertTrue(workspace.debugHasPendingReparentFocusSuppressionsForTesting())
        XCTAssertTrue(panel.hostedView.debugIsSuppressingReparentFocusForTesting())

        workspace.debugAttemptEventDrivenLayoutFollowUpForTesting()

        XCTAssertFalse(workspace.debugHasPendingReparentFocusSuppressionsForTesting())
        XCTAssertFalse(panel.hostedView.debugIsSuppressingReparentFocusForTesting())
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }
}


@MainActor
final class WorkspaceSidebarExtensionBrowserSurfaceTests: XCTestCase {
    func testCreatesExtensionBrowserTabInFocusedPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              let leftPaneId = workspace.paneId(forPanelId: leftPanelId) else {
            XCTFail("Expected split workspace setup to succeed")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)

        workspace.focusPanel(leftPanelId)
        XCTAssertEqual(workspace.bonsplitController.focusedPaneId, leftPaneId)

        guard let extensionBrowserPanel = workspace.newSidebarExtensionBrowserSurface(
            inPane: leftPaneId,
            title: "Sidebar Extensions",
            focus: true
        ) else {
            XCTFail("Expected extension browser tab creation to succeed")
            return
        }

        XCTAssertEqual(extensionBrowserPanel.panelType, .extensionBrowser)
        XCTAssertEqual(workspace.focusedPanelId, extensionBrowserPanel.id)
        XCTAssertEqual(workspace.paneId(forPanelId: extensionBrowserPanel.id), leftPaneId)
        XCTAssertNotEqual(workspace.paneId(forPanelId: extensionBrowserPanel.id), workspace.paneId(forPanelId: rightPanel.id))
    }
}


@MainActor
final class WorkspaceTerminalConfigInheritanceSelectionTests: XCTestCase {
    func testPrefersSelectedTerminalInTargetPaneOverFocusedTerminalElsewhere() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              let leftPaneId = workspace.paneId(forPanelId: leftPanelId) else {
            XCTFail("Expected workspace split setup to succeed")
            return
        }

        // Programmatic split focuses the new right panel by default.
        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: leftPaneId)
        XCTAssertEqual(
            sourcePanel?.id,
            leftPanelId,
            "Expected inheritance to use the selected terminal in the target pane"
        )
    }

    func testFallsBackToAnotherTerminalInPaneWhenSelectedTabIsBrowser() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: terminalPanelId),
              let browserPanel = workspace.newBrowserSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected workspace browser setup to succeed")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: paneId)
        XCTAssertEqual(
            sourcePanel?.id,
            terminalPanelId,
            "Expected inheritance to fall back to a terminal in the pane when browser is selected"
        )
    }

    func testPreferredTerminalPanelWinsWhenProvided() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let terminalPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a terminal panel")
            return
        }

        let sourcePanel = workspace.terminalPanelForConfigInheritance(preferredPanelId: terminalPanelId)
        XCTAssertEqual(sourcePanel?.id, terminalPanelId)
    }

    func testPrefersLastFocusedTerminalWhenBrowserFocusedInDifferentPane() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftTerminalPanelId = workspace.focusedPanelId,
              let rightTerminalPanel = workspace.newTerminalSplit(from: leftTerminalPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightTerminalPanel.id) else {
            XCTFail("Expected split setup to succeed")
            return
        }

        workspace.focusPanel(leftTerminalPanelId)
        _ = workspace.newBrowserSurface(inPane: rightPaneId, focus: true)
        XCTAssertNotEqual(workspace.focusedPanelId, leftTerminalPanelId)

        let sourcePanel = workspace.terminalPanelForConfigInheritance(inPane: rightPaneId)
        XCTAssertEqual(
            sourcePanel?.id,
            leftTerminalPanelId,
            "Expected inheritance to prefer last focused terminal when browser is focused in another pane"
        )
    }
}


@MainActor
final class WorkspaceAttentionFlashTests: XCTestCase {
    func testMoveFocusDoesNotTriggerWholePaneFlashTokenWhenWholePaneModeEnabled() {
        let defaults = UserDefaults.standard
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)

        defer {
            if let originalExperimentEnabled {
                defaults.set(originalExperimentEnabled, forKey: TmuxOverlayExperimentSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let originalExperimentTarget {
                defaults.set(originalExperimentTarget, forKey: TmuxOverlayExperimentSettings.targetKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
        }

        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.bonsplitPane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertEqual(workspace.tmuxWorkspaceFlashToken, 0)
        XCTAssertNil(workspace.tmuxWorkspaceFlashPanelId)

        workspace.moveFocus(direction: .left)

        XCTAssertEqual(workspace.focusedPanelId, leftPanelId)
        XCTAssertEqual(
            workspace.tmuxWorkspaceFlashToken,
            0,
            "Expected moving focus left to avoid any workspace-pane flash"
        )
        XCTAssertNil(workspace.tmuxWorkspaceFlashPanelId)

        workspace.moveFocus(direction: .right)

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertEqual(
            workspace.tmuxWorkspaceFlashToken,
            0,
            "Expected moving focus right to avoid any workspace-pane flash"
        )
        XCTAssertNil(workspace.tmuxWorkspaceFlashPanelId)
    }

    func testMoveFocusSuppressesWorkspacePaneFlashWhenAnotherPaneOwnsUnreadAttention() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let notificationStore = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        defer {
            notificationStore.replaceNotificationsForTesting([])
            notificationStore.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalExperimentEnabled {
                defaults.set(originalExperimentEnabled, forKey: TmuxOverlayExperimentSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let originalExperimentTarget {
                defaults.set(originalExperimentTarget, forKey: TmuxOverlayExperimentSettings.targetKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
        }

        notificationStore.replaceNotificationsForTesting([])
        notificationStore.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = notificationStore
        AppFocusState.overrideIsFocused = true
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.bonsplitPane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)

        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split terminal panels")
            return
        }

        workspace.moveFocus(direction: .left)

        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: leftPanelId,
            title: "Unread",
            subtitle: "",
            body: "Left pane owns notification attention"
        )

        XCTAssertTrue(
            notificationStore.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: leftPanelId),
            "Expected the left pane to own visible notification attention before moving focus"
        )

        let flashTokenBeforeNavigation = workspace.tmuxWorkspaceFlashToken

        workspace.moveFocus(direction: .right)

        XCTAssertEqual(workspace.focusedPanelId, rightPanel.id)
        XCTAssertEqual(
            workspace.tmuxWorkspaceFlashToken,
            flashTokenBeforeNavigation,
            "Expected navigation flash to be suppressed while another pane owns notification attention"
        )
    }
}


@MainActor
final class WorkspaceBrowserProfileSelectionTests: XCTestCase {
    private final class RejectingCreateTabDelegate: BonsplitDelegate {
        func splitTabBar(_ controller: BonsplitController, shouldCreateTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
            false
        }
    }

    private final class RejectingSplitPaneDelegate: BonsplitDelegate {
        func splitTabBar(_ controller: BonsplitController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool {
            false
        }
    }

    func testNewBrowserSurfacePrefersSelectedBrowserProfileInTargetPane() throws {
        let workspace = Workspace()
        let profileA = try makeTemporaryBrowserProfile(named: "Alpha")
        let profileB = try makeTemporaryBrowserProfile(named: "Beta")
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let browserA = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                focus: true,
                preferredProfileID: profileA.id
            )
        )
        _ = try XCTUnwrap(
            workspace.newBrowserSplit(
                from: browserA.id,
                orientation: .horizontal,
                preferredProfileID: profileB.id,
                focus: true
            )
        )

        XCTAssertEqual(
            workspace.preferredBrowserProfileID,
            profileB.id,
            "Expected workspace preference to drift to the most recently created browser profile"
        )

        let leftSurfaceId = try XCTUnwrap(workspace.surfaceIdFromPanelId(browserA.id))
        workspace.bonsplitController.focusPane(paneId)
        workspace.bonsplitController.selectTab(leftSurfaceId)

        let created = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                focus: false
            )
        )

        XCTAssertEqual(
            created.profileID,
            profileA.id,
            "Expected new browser creation to inherit the selected browser profile from the target pane"
        )
    }

    func testNewBrowserSurfaceFailureDoesNotMutatePreferredProfile() throws {
        let workspace = Workspace()
        let preferredProfile = try makeTemporaryBrowserProfile(named: "Preferred")
        let unexpectedProfile = try makeTemporaryBrowserProfile(named: "Unexpected")

        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        _ = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                focus: false,
                preferredProfileID: preferredProfile.id
            )
        )
        XCTAssertEqual(workspace.preferredBrowserProfileID, preferredProfile.id)

        let rejectingDelegate = RejectingCreateTabDelegate()
        workspace.bonsplitController.delegate = rejectingDelegate
        let created = workspace.newBrowserSurface(
            inPane: paneId,
            focus: false,
            preferredProfileID: unexpectedProfile.id
        )

        XCTAssertNil(created)
        XCTAssertEqual(
            workspace.preferredBrowserProfileID,
            preferredProfile.id,
            "Expected a failed browser creation to leave the workspace preferred profile unchanged"
        )
    }

    func testNewBrowserSplitFailureDoesNotMutatePreferredProfile() throws {
        let workspace = Workspace()
        let preferredProfile = try makeTemporaryBrowserProfile(named: "Preferred")
        let unexpectedProfile = try makeTemporaryBrowserProfile(named: "Unexpected")

        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let browser = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                focus: true,
                preferredProfileID: preferredProfile.id
            )
        )
        XCTAssertEqual(workspace.preferredBrowserProfileID, preferredProfile.id)

        let rejectingDelegate = RejectingSplitPaneDelegate()
        workspace.bonsplitController.delegate = rejectingDelegate
        let created = workspace.newBrowserSplit(
            from: browser.id,
            orientation: .horizontal,
            preferredProfileID: unexpectedProfile.id,
            focus: false
        )

        XCTAssertNil(created)
        XCTAssertEqual(
            workspace.preferredBrowserProfileID,
            preferredProfile.id,
            "Expected a failed browser split to leave the workspace preferred profile unchanged"
        )
    }
}


@MainActor
final class WorkspacePanelGitBranchTests: XCTestCase {
    private final class RejectingCreateTabDelegate: BonsplitDelegate {
        func splitTabBar(_ controller: BonsplitController, shouldCreateTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
            false
        }
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    private func rootSplit(in workspace: Workspace) throws -> ExternalSplitNode {
        switch workspace.bonsplitController.treeSnapshot() {
        case .split(let split):
            return split
        case .pane:
            let split: ExternalSplitNode? = nil
            return try XCTUnwrap(split, "Expected workspace root to be a split")
        }
    }

    private func paneId(in node: ExternalTreeNode) throws -> String {
        switch node {
        case .pane(let pane):
            return pane.id
        case .split:
            let paneId: String? = nil
            return try XCTUnwrap(paneId, "Expected split child to be a pane")
        }
    }

    func testBrowserSplitWithFocusFalsePreservesOriginalFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let browserSplitPanel = workspace.newBrowserSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }

        drainMainQueue()

        XCTAssertNotEqual(browserSplitPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus browser split to preserve pre-split focus"
        )
    }

    func testTerminalSplitWithFocusFalsePreservesOriginalFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let terminalSplitPanel = workspace.newTerminalSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected terminal split panel to be created")
            return
        }

        drainMainQueue()

        XCTAssertNotEqual(terminalSplitPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus terminal split to preserve pre-split focus"
        )
    }

    func testDetachLastSurfaceLeavesWorkspaceTemporarilyEmptyForMoveFlow() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: panelId) else {
            XCTFail("Expected initial panel and pane")
            return
        }

        XCTAssertEqual(workspace.panels.count, 1)
#if DEBUG
        let baselineFocusReconcileDuringDetach = workspace.debugFocusReconcileScheduledDuringDetachCount
#endif

        guard let detached = workspace.detachSurface(panelId: panelId) else {
            XCTFail("Expected detach of last surface to succeed")
            return
        }

        XCTAssertEqual(detached.panelId, panelId)
        XCTAssertTrue(
            workspace.panels.isEmpty,
            "Detaching the last surface should not auto-create a replacement panel"
        )
        XCTAssertNil(workspace.surfaceIdFromPanelId(panelId))
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: paneId).count, 0)

        drainMainQueue()
        drainMainQueue()
#if DEBUG
        XCTAssertEqual(
            workspace.debugFocusReconcileScheduledDuringDetachCount,
            baselineFocusReconcileDuringDetach,
            "Detaching during cross-workspace moves should not schedule delayed source focus reconciliation"
        )
#endif

        let restoredPanelId = workspace.attachDetachedSurface(detached, inPane: paneId, focus: false)
        XCTAssertEqual(restoredPanelId, panelId)
        XCTAssertEqual(workspace.panels.count, 1)
    }

    func testFailedAttachDoesNotRebindDetachedTerminalPanelToDestinationWorkspace() {
        let source = Workspace()
        guard let panelId = source.focusedPanelId,
              let sourceTerminalPanel = source.panels[panelId] as? TerminalPanel else {
            XCTFail("Expected initial terminal panel")
            return
        }

        XCTAssertEqual(sourceTerminalPanel.workspaceId, source.id)

        guard let detached = source.detachSurface(panelId: panelId),
              let detachedTerminalPanel = detached.panel as? TerminalPanel else {
            XCTFail("Expected terminal detach transfer")
            return
        }

        XCTAssertEqual(detachedTerminalPanel.workspaceId, source.id)

        let destination = Workspace()
        guard let destinationPaneId = destination.bonsplitController.focusedPaneId else {
            XCTFail("Expected destination pane")
            return
        }

        let rejectingDelegate = RejectingCreateTabDelegate()
        destination.bonsplitController.delegate = rejectingDelegate

        let attachedPanelId = destination.attachDetachedSurface(
            detached,
            inPane: destinationPaneId,
            focus: false
        )

        XCTAssertNil(attachedPanelId)
        XCTAssertNil(destination.panels[panelId])
        XCTAssertNil(destination.surfaceIdFromPanelId(panelId))
        XCTAssertEqual(
            detachedTerminalPanel.workspaceId,
            source.id,
            "A failed attach should leave the detached panel bound to its source workspace for retry"
        )
    }

    func testDetachSurfaceWithRemainingPanelsSkipsDelayedFocusReconcile() {
        let workspace = Workspace()
        guard let originalPanelId = workspace.focusedPanelId,
              let movedPanel = workspace.newTerminalSplit(from: originalPanelId, orientation: .horizontal) else {
            XCTFail("Expected two panels before detach")
            return
        }

        drainMainQueue()
        drainMainQueue()
#if DEBUG
        let baselineFocusReconcileDuringDetach = workspace.debugFocusReconcileScheduledDuringDetachCount
#endif

        guard let detached = workspace.detachSurface(panelId: movedPanel.id) else {
            XCTFail("Expected detach to succeed")
            return
        }

        XCTAssertEqual(detached.panelId, movedPanel.id)
        XCTAssertEqual(workspace.panels.count, 1, "Expected source workspace to retain only the surviving panel")
        XCTAssertNotNil(workspace.panels[originalPanelId], "Expected the original panel to remain after detach")

        drainMainQueue()
        drainMainQueue()
#if DEBUG
        XCTAssertEqual(
            workspace.debugFocusReconcileScheduledDuringDetachCount,
            baselineFocusReconcileDuringDetach,
            "Detaching into another workspace should not enqueue delayed source focus reconciliation"
        )
#endif
    }

    func testDetachAttachAcrossWorkspacesPreservesNonCustomPanelTitle() {
        let source = Workspace()
        guard let panelId = source.focusedPanelId else {
            XCTFail("Expected source focused panel")
            return
        }

        XCTAssertTrue(source.updatePanelTitle(panelId: panelId, title: "detached-runtime-title"))

        guard let detached = source.detachSurface(panelId: panelId) else {
            XCTFail("Expected detach to succeed")
            return
        }

        XCTAssertEqual(detached.cachedTitle, "detached-runtime-title")
        XCTAssertNil(detached.customTitle)
        XCTAssertEqual(
            detached.title,
            "detached-runtime-title",
            "Detached transfer should carry the cached non-custom title"
        )

        let destination = Workspace()
        guard let destinationPane = destination.bonsplitController.allPaneIds.first else {
            XCTFail("Expected destination pane")
            return
        }

        let attachedPanelId = destination.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        )
        XCTAssertEqual(attachedPanelId, panelId)
        XCTAssertEqual(destination.panelTitle(panelId: panelId), "detached-runtime-title")

        guard let attachedTabId = destination.surfaceIdFromPanelId(panelId),
              let attachedTab = destination.bonsplitController.tab(attachedTabId) else {
            XCTFail("Expected attached tab mapping")
            return
        }
        XCTAssertEqual(attachedTab.title, "detached-runtime-title")
        XCTAssertFalse(attachedTab.hasCustomTitle)
    }

    func testBrowserSplitWithFocusFalseRecoversFromDelayedStaleSelection() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }
        guard let originalPaneId = workspace.paneId(forPanelId: originalFocusedPanelId) else {
            XCTFail("Expected focused pane for initial panel")
            return
        }

        guard let browserSplitPanel = workspace.newBrowserSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }
        guard let splitPaneId = workspace.paneId(forPanelId: browserSplitPanel.id),
              let splitTabId = workspace.surfaceIdFromPanelId(browserSplitPanel.id),
              let splitTab = workspace.bonsplitController
              .tabs(inPane: splitPaneId)
              .first(where: { $0.id == splitTabId }) else {
            XCTFail("Expected split pane/tab mapping")
            return
        }

        // Simulate one delayed stale split-selection callback from bonsplit.
        DispatchQueue.main.async {
            workspace.splitTabBar(workspace.bonsplitController, didSelectTab: splitTab, inPane: splitPaneId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus split to reassert the pre-split focused panel"
        )
        XCTAssertEqual(
            workspace.bonsplitController.focusedPaneId,
            originalPaneId,
            "Expected focused pane to converge back to the pre-split pane"
        )
        XCTAssertEqual(
            workspace.bonsplitController.selectedTab(inPane: originalPaneId)?.id,
            workspace.surfaceIdFromPanelId(originalFocusedPanelId),
            "Expected selected tab to converge back to the pre-split focused panel"
        )
    }

    func testBrowserSplitWithFocusFalseAllowsSubsequentExplicitFocusOnSplitPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        guard let browserSplitPanel = workspace.newBrowserSplit(
            from: originalFocusedPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            XCTFail("Expected browser split panel to be created")
            return
        }

        workspace.focusPanel(browserSplitPanel.id)

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            workspace.focusedPanelId,
            browserSplitPanel.id,
            "Expected explicit focus intent to keep the split panel focused"
        )
    }

    func testNewTerminalSurfaceWithFocusFalsePreservesFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId,
              let originalPaneId = workspace.paneId(forPanelId: originalFocusedPanelId) else {
            XCTFail("Expected initial focused panel and pane")
            return
        }

        guard let newPanel = workspace.newTerminalSurface(inPane: originalPaneId, focus: false) else {
            XCTFail("Expected terminal surface to be created")
            return
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertNotEqual(newPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus terminal surface creation to preserve the existing focused panel"
        )
        XCTAssertEqual(
            workspace.bonsplitController.selectedTab(inPane: originalPaneId)?.id,
            workspace.surfaceIdFromPanelId(originalFocusedPanelId),
            "Expected selected tab to stay on the original focused panel"
        )
    }

    func testNewBrowserSurfaceWithFocusFalsePreservesFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId,
              let originalPaneId = workspace.paneId(forPanelId: originalFocusedPanelId) else {
            XCTFail("Expected initial focused panel and pane")
            return
        }

        guard let newPanel = workspace.newBrowserSurface(inPane: originalPaneId, focus: false) else {
            XCTFail("Expected browser surface to be created")
            return
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertNotEqual(newPanel.id, originalFocusedPanelId)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus browser surface creation to preserve the existing focused panel"
        )
        XCTAssertEqual(
            workspace.bonsplitController.selectedTab(inPane: originalPaneId)?.id,
            workspace.surfaceIdFromPanelId(originalFocusedPanelId),
            "Expected selected tab to stay on the original focused panel"
        )
    }

    func testNewRightSidebarToolSurfaceWithFocusFalsePreservesFocusedPanel() {
        let workspace = Workspace()
        guard let originalFocusedPanelId = workspace.focusedPanelId,
              let originalPaneId = workspace.paneId(forPanelId: originalFocusedPanelId),
              let originalTabId = workspace.surfaceIdFromPanelId(originalFocusedPanelId) else {
            XCTFail("Expected initial focused panel, pane, and tab")
            return
        }

        guard let newPanel = workspace.newRightSidebarToolSurface(
            inPane: originalPaneId,
            mode: .files,
            focus: false
        ) else {
            XCTFail("Expected right sidebar tool surface to be created")
            return
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertNotEqual(newPanel.id, originalFocusedPanelId)
        XCTAssertEqual(newPanel.panelType, .rightSidebarTool)
        XCTAssertEqual(newPanel.mode, .files)
        XCTAssertEqual(
            workspace.focusedPanelId,
            originalFocusedPanelId,
            "Expected non-focus right sidebar tool surface creation to preserve the existing focused panel"
        )
        XCTAssertEqual(
            workspace.bonsplitController.selectedTab(inPane: originalPaneId)?.id,
            originalTabId,
            "Expected selected tab to stay on the original focused panel"
        )
        XCTAssertEqual(
            workspace.surfaceIdFromPanelId(newPanel.id).flatMap { workspace.bonsplitController.tab($0)?.kind },
            SurfaceKind.rightSidebarTool.rawValue
        )
    }

    func testOpenOrFocusRightSidebarToolSurfaceReusesExistingMode() {
        let workspace = Workspace()
        guard let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected focused pane")
            return
        }

        guard let firstPanel = workspace.openOrFocusRightSidebarToolSurface(
            inPane: paneId,
            mode: .sessions,
            focus: true
        ) else {
            XCTFail("Expected Vault tool surface to be created")
            return
        }
        guard let secondPanel = workspace.openOrFocusRightSidebarToolSurface(
            inPane: paneId,
            mode: .sessions,
            focus: true
        ) else {
            XCTFail("Expected existing Vault tool surface to be focused")
            return
        }

        XCTAssertEqual(firstPanel.id, secondPanel.id)
        XCTAssertEqual(
            workspace.panels.values.compactMap { $0 as? RightSidebarToolPanel }.filter { $0.mode == .sessions }.count,
            1
        )
        XCTAssertEqual(workspace.focusedPanelId, firstPanel.id)
    }

    func testClosingFocusedSplitRestoresBranchForRemainingFocusedPanel() {
        let workspace = Workspace()
        guard let firstPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: firstPanelId, branch: "main", isDirty: false)
        guard let secondPanel = workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }

        workspace.updatePanelGitBranch(panelId: secondPanel.id, branch: "feature/bugfix", isDirty: true)
        XCTAssertEqual(workspace.focusedPanelId, secondPanel.id, "Expected split panel to be focused")
        XCTAssertEqual(workspace.gitBranch?.branch, "feature/bugfix")
        XCTAssertEqual(workspace.gitBranch?.isDirty, true)

        XCTAssertTrue(workspace.closePanel(secondPanel.id, force: true), "Expected split panel close to succeed")
        XCTAssertEqual(workspace.focusedPanelId, firstPanelId, "Expected surviving panel to become focused")
        XCTAssertEqual(workspace.gitBranch?.branch, "main")
        XCTAssertEqual(workspace.gitBranch?.isDirty, false)
    }

    func testForkAgentConversationToRightCreatesRightSplitWithForkStartupInput() throws {
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePanel = try XCTUnwrap(workspace.terminalPanel(for: sourcePanelId))
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/tmp/fork repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--search",
                    "initial prompt should not replay"
                ],
                workingDirectory: "/tmp/fork repo",
                environment: ["CODEX_HOME": "/tmp/codex"],
                capturedAt: 123,
                source: "process"
            )
        )

        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversation(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                direction: .right
            )
        )

        XCTAssertNotEqual(forkPanel.id, sourcePanelId)
        XCTAssertEqual(workspace.terminalPanel(for: sourcePanelId)?.id, sourcePanel.id)
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 2)
        XCTAssertEqual(workspace.focusedPanelId, forkPanel.id)
        XCTAssertEqual(forkPanel.requestedWorkingDirectory, "/tmp/fork repo")
        XCTAssertEqual(forkPanel.surface.initialInput, snapshot.forkCommand.map { $0 + "\n" })
        let split = try rootSplit(in: workspace)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId)).id.uuidString
        let forkPaneId = try XCTUnwrap(workspace.paneId(forPanelId: forkPanel.id)).id.uuidString
        XCTAssertEqual(split.orientation, "horizontal")
        XCTAssertEqual(try paneId(in: split.first), sourcePaneId)
        XCTAssertEqual(try paneId(in: split.second), forkPaneId)
    }

    func testForkAgentConversationSupportsAllSplitDirections() throws {
        for direction in [SplitDirection.left, .right, .up, .down] {
            let workspace = Workspace()
            let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
            let snapshot = SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
                workingDirectory: "/tmp/fork repo",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "codex",
                    executablePath: "/Users/example/.bun/bin/codex",
                    arguments: ["/Users/example/.bun/bin/codex", "--search"],
                    workingDirectory: "/tmp/fork repo",
                    environment: nil,
                    capturedAt: 123,
                    source: "process"
                )
            )

            let forkPanel = try XCTUnwrap(
                workspace.forkAgentConversation(
                    fromPanelId: sourcePanelId,
                    snapshot: snapshot,
                    direction: direction
                )
            )

            XCTAssertNotEqual(forkPanel.id, sourcePanelId)
            XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 2)
            XCTAssertEqual(workspace.focusedPanelId, forkPanel.id)
            XCTAssertEqual(forkPanel.requestedWorkingDirectory, "/tmp/fork repo")
            XCTAssertEqual(forkPanel.surface.initialInput, snapshot.forkCommand.map { $0 + "\n" })
            let split = try rootSplit(in: workspace)
            let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId)).id.uuidString
            let forkPaneId = try XCTUnwrap(workspace.paneId(forPanelId: forkPanel.id)).id.uuidString
            XCTAssertEqual(split.orientation, direction.isHorizontal ? "horizontal" : "vertical")
            XCTAssertEqual(
                try paneId(in: split.first),
                direction.insertFirst ? forkPaneId : sourcePaneId
            )
            XCTAssertEqual(
                try paneId(in: split.second),
                direction.insertFirst ? sourcePaneId : forkPaneId
            )
        }
    }

    func testForkAgentConversationUsesWorkspaceDirectoryFallback() throws {
        let workspace = Workspace()
        workspace.currentDirectory = "/tmp/workspace fork repo"
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversation(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                direction: .right
            )
        )

        XCTAssertEqual(forkPanel.requestedWorkingDirectory, "/tmp/workspace fork repo")
        XCTAssertEqual(
            forkPanel.surface.initialInput,
            "{ cd -- '/tmp/workspace fork repo' 2>/dev/null || [ ! -d '/tmp/workspace fork repo' ]; } && '/Users/example/.bun/bin/codex' 'fork' '019dad34-d218-7943-b81a-eddac5c87951'\n"
        )
    }

    func testForkAgentConversationInRemoteWorkspaceUsesRemoteStartupCommand() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-fork",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-fork-remote.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        let initialRemoteSessionCount = workspace.activeRemoteTerminalSessionCount
        XCTAssertEqual(initialRemoteSessionCount, 1)
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversation(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                direction: .right
            )
        )

        XCTAssertEqual(forkPanel.surface.debugInitialCommand(), "ssh cmux-macmini")
        XCTAssertNil(forkPanel.requestedWorkingDirectory)
        XCTAssertEqual(workspace.panelDirectories[forkPanel.id], "/Users/cmux/project")
        XCTAssertEqual(forkPanel.surface.initialInput, snapshot.forkCommand.map { $0 + "\n" })
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, initialRemoteSessionCount + 1)
    }

    func testForkAgentConversationInRemoteWorkspaceUsesFallbackDirectoryInForkCommand() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-fork-fallback",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-fork-fallback-remote.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        workspace.currentDirectory = "/Users/cmux/fallback repo"
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversation(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                direction: .right
            )
        )

        XCTAssertEqual(forkPanel.surface.debugInitialCommand(), "ssh cmux-macmini")
        XCTAssertNil(forkPanel.requestedWorkingDirectory)
        XCTAssertEqual(workspace.panelDirectories[forkPanel.id], "/Users/cmux/fallback repo")
        XCTAssertEqual(
            forkPanel.surface.initialInput,
            "{ cd -- '/Users/cmux/fallback repo' 2>/dev/null || [ ! -d '/Users/cmux/fallback repo' ]; } && '/Users/example/.bun/bin/codex' 'fork' '019dad34-d218-7943-b81a-eddac5c87951'\n"
        )
    }

    func testSessionIndexRemoteSplitDoesNotInjectRemoteStartupCommand() throws {
        let fileManager = FileManager.default
        let hookStateRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-session-drop-hook-state-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: hookStateRoot, withIntermediateDirectories: true)
        let previousHookStateDir = getenv("CMUX_AGENT_HOOK_STATE_DIR").map { String(cString: $0) }
        setenv("CMUX_AGENT_HOOK_STATE_DIR", hookStateRoot.path, 1)
        defer {
            if let previousHookStateDir {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDir, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
            try? fileManager.removeItem(at: hookStateRoot)
        }

        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-session-drop",
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-session-drop-remote.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        let initialRemoteSessionCount = workspace.activeRemoteTerminalSessionCount
        XCTAssertEqual(initialRemoteSessionCount, 1)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let initialInput = "codex resume session-drop\n"

        let splitPanel = try XCTUnwrap(
            workspace.splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: .horizontal,
                insertFirst: false,
                workingDirectory: "/Users/cmux/project",
                initialInput: initialInput
            )
        )

        XCTAssertNil(splitPanel.surface.debugInitialCommand())
        XCTAssertEqual(splitPanel.surface.initialInput, initialInput)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, initialRemoteSessionCount)
    }

    func testForkAgentWorkspaceLaunchInRemoteWorkspacePreservesRemoteContext() throws {
        let workspace = Workspace()
        let agentSocketPath = "/tmp/cmux-fork-agent.sock"
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: 2222,
                identityFile: "/Users/example/.ssh/cmux",
                sshOptions: ["ServerAliveInterval=30", "ForwardAgent=yes"],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-fork",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-fork-remote.sock",
                terminalStartupCommand: "ssh -p 2222 -i /Users/example/.ssh/cmux -o ServerAliveInterval=30 -o ForwardAgent=yes -tt cmux-macmini",
                agentSocketPath: agentSocketPath
            ),
            autoConnect: false
        )
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let launch = try XCTUnwrap(
            workspace.forkAgentWorkspaceLaunch(
                fromPanelId: sourcePanelId,
                snapshot: snapshot
            )
        )

        XCTAssertEqual(launch.workingDirectory, "/Users/cmux/project")
        XCTAssertNil(launch.terminalWorkingDirectory)
        XCTAssertEqual(
            launch.initialTerminalCommand,
            "ssh -p 2222 -i /Users/example/.ssh/cmux -o ServerAliveInterval=30 -o ForwardAgent=yes -tt cmux-macmini"
        )
        XCTAssertEqual(launch.initialTerminalInput, snapshot.forkCommand.map { $0 + "\n" })
        XCTAssertEqual(launch.initialTerminalEnvironment["SSH_AUTH_SOCK"], agentSocketPath)
        XCTAssertTrue(launch.autoConnectRemoteConfiguration)
        XCTAssertEqual(launch.remoteConfiguration?.destination, "cmux-macmini")
        XCTAssertEqual(launch.remoteConfiguration?.port, 2222)
        XCTAssertEqual(launch.remoteConfiguration?.identityFile, "/Users/example/.ssh/cmux")
        XCTAssertEqual(launch.remoteConfiguration?.sshOptions, ["ServerAliveInterval=30", "ForwardAgent=yes"])
        XCTAssertEqual(launch.remoteConfiguration?.agentSocketPath, agentSocketPath)
        XCTAssertEqual(launch.remoteConfiguration?.sshTerminalStartupEnvironment?["SSH_AUTH_SOCK"], agentSocketPath)
        XCTAssertEqual(launch.remoteConfiguration?.sshProcessEnvironment?["SSH_AUTH_SOCK"], agentSocketPath)
        XCTAssertNil(launch.remoteConfiguration?.relayPort)
        XCTAssertNil(launch.remoteConfiguration?.localSocketPath)
    }

    func testForkAgentWorkspaceLaunchFromPersistentSSHPTYDoesNotReuseParentRelayOrDaemonSlot() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: 2222,
                identityFile: "/Users/example/.ssh/cmux",
                sshOptions: ["ControlMaster=auto", "ControlPersist=600"],
                localProxyPort: nil,
                relayPort: 64017,
                relayID: "relay-fork-persistent",
                relayToken: String(repeating: "c", count: 64),
                localSocketPath: "/tmp/cmux-fork-persistent.sock",
                terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "ssh-parent-slot"
            ),
            autoConnect: false
        )
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let launch = try XCTUnwrap(
            workspace.forkAgentWorkspaceLaunch(
                fromPanelId: sourcePanelId,
                snapshot: snapshot
            )
        )

        XCTAssertTrue(launch.autoConnectRemoteConfiguration)
        XCTAssertEqual(launch.remoteConfiguration?.destination, "cmux-macmini")
        XCTAssertEqual(launch.remoteConfiguration?.port, 2222)
        XCTAssertEqual(launch.remoteConfiguration?.preserveAfterTerminalExit, false)
        XCTAssertNil(launch.remoteConfiguration?.relayPort)
        XCTAssertNil(launch.remoteConfiguration?.relayID)
        XCTAssertNil(launch.remoteConfiguration?.relayToken)
        XCTAssertNil(launch.remoteConfiguration?.localSocketPath)
        XCTAssertNil(launch.remoteConfiguration?.persistentDaemonSlot)
        let startupCommand = try XCTUnwrap(launch.remoteConfiguration?.terminalStartupCommand)
        XCTAssertFalse(startupCommand.contains("ssh-pty-attach"), startupCommand)
        XCTAssertEqual(
            startupCommand,
            "ssh -p 2222 -i /Users/example/.ssh/cmux -tt cmux-macmini"
        )
    }

    func testForkAgentWorkspaceLaunchInRemoteWorkspaceUsesFallbackDirectoryInForkCommand() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-workspace-fallback",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-workspace-fallback-remote.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        workspace.currentDirectory = "/Users/cmux/fallback repo"
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let launch = try XCTUnwrap(
            workspace.forkAgentWorkspaceLaunch(
                fromPanelId: sourcePanelId,
                snapshot: snapshot
            )
        )

        XCTAssertEqual(launch.workingDirectory, "/Users/cmux/fallback repo")
        XCTAssertNil(launch.terminalWorkingDirectory)
        XCTAssertEqual(launch.initialTerminalCommand, "ssh -tt cmux-macmini")
        XCTAssertEqual(
            launch.initialTerminalInput,
            "{ cd -- '/Users/cmux/fallback repo' 2>/dev/null || [ ! -d '/Users/cmux/fallback repo' ]; } && '/Users/example/.bun/bin/codex' 'fork' '019dad34-d218-7943-b81a-eddac5c87951'\n"
        )
    }

    func testForkAgentWorkspaceLaunchInLocalWorkspaceUsesLocalTerminalWorkingDirectory() throws {
        let workspace = Workspace()
        workspace.currentDirectory = "/tmp/local fork repo"
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let launch = try XCTUnwrap(
            workspace.forkAgentWorkspaceLaunch(
                fromPanelId: sourcePanelId,
                snapshot: snapshot
            )
        )

        XCTAssertEqual(launch.workingDirectory, "/tmp/local fork repo")
        XCTAssertEqual(launch.terminalWorkingDirectory, "/tmp/local fork repo")
        XCTAssertNil(launch.initialTerminalCommand)
        XCTAssertFalse(launch.autoConnectRemoteConfiguration)
        XCTAssertNil(launch.remoteConfiguration)
        XCTAssertEqual(
            launch.initialTerminalInput,
            "{ cd -- '/tmp/local fork repo' 2>/dev/null || [ ! -d '/tmp/local fork repo' ]; } && '/Users/example/.bun/bin/codex' 'fork' '019dad34-d218-7943-b81a-eddac5c87951'\n"
        )
    }

    func testForkAgentConversationInRemoteConfiguredLocalWorkspaceAllowsLauncherScript() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                transport: .websocket,
                destination: "cloud-vm",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: 54321,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: nil
            ),
            autoConnect: false
        )
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let longPath = "/Users/cmux/" + String(repeating: "nested-project-", count: 120)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    longPath
                ],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertGreaterThan(
            (snapshot.forkCommand.map { $0 + "\n" } ?? "").utf8.count,
            SessionRestorableAgentSnapshot.maxInlineStartupInputBytes
        )
        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversation(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                direction: .right
            )
        )
        XCTAssertNil(forkPanel.surface.debugInitialCommand())
        XCTAssertEqual(forkPanel.requestedWorkingDirectory, "/Users/cmux/project")
        XCTAssertTrue(forkPanel.surface.initialInput?.hasPrefix("/bin/zsh ") == true)

        let launch = try XCTUnwrap(
            workspace.forkAgentWorkspaceLaunch(
                fromPanelId: sourcePanelId,
                snapshot: snapshot
            )
        )
        XCTAssertEqual(launch.terminalWorkingDirectory, "/Users/cmux/project")
        XCTAssertNil(launch.initialTerminalCommand)
        XCTAssertFalse(launch.autoConnectRemoteConfiguration)
        XCTAssertNil(launch.remoteConfiguration)
        XCTAssertTrue(launch.initialTerminalInput.hasPrefix("/bin/zsh "))
    }

    func testForkAgentConversationFromLocalTerminalInRemoteWorkspaceStaysLocal() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-fork-local",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-fork-local-remote.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        let initialRemoteSessionCount = workspace.activeRemoteTerminalSessionCount
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let localPanel = try XCTUnwrap(
            workspace.splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: .horizontal,
                insertFirst: false,
                workingDirectory: "/tmp/local project",
                initialInput: nil
            )
        )
        let longPath = "/tmp/local/" + String(repeating: "nested-project-", count: 120)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/tmp/local project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    longPath
                ],
                workingDirectory: "/tmp/local project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversation(
                fromPanelId: localPanel.id,
                snapshot: snapshot,
                direction: .right
            )
        )
        XCTAssertNil(forkPanel.surface.debugInitialCommand())
        XCTAssertEqual(forkPanel.requestedWorkingDirectory, "/tmp/local project")
        XCTAssertTrue(forkPanel.surface.initialInput?.hasPrefix("/bin/zsh ") == true)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, initialRemoteSessionCount)

        let launch = try XCTUnwrap(
            workspace.forkAgentWorkspaceLaunch(
                fromPanelId: localPanel.id,
                snapshot: snapshot
            )
        )
        XCTAssertEqual(launch.terminalWorkingDirectory, "/tmp/local project")
        XCTAssertNil(launch.initialTerminalCommand)
        XCTAssertFalse(launch.autoConnectRemoteConfiguration)
        XCTAssertNil(launch.remoteConfiguration)
        XCTAssertTrue(launch.initialTerminalInput.hasPrefix("/bin/zsh "))
    }

    func testForkAgentConversationInRemoteWorkspaceRejectsLocalLauncherScriptFallback() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-fork",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-fork-remote.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let longPath = "/Users/cmux/" + String(repeating: "nested-project-", count: 120)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    longPath
                ],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertGreaterThan(
            (snapshot.forkCommand.map { $0 + "\n" } ?? "").utf8.count,
            SessionRestorableAgentSnapshot.maxInlineStartupInputBytes
        )
        XCTAssertNil(snapshot.forkStartupInput(allowLauncherScript: false))
        XCTAssertNil(
            workspace.forkAgentConversation(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                direction: .right
            )
        )
        XCTAssertNil(
            workspace.forkAgentWorkspaceLaunch(
                fromPanelId: sourcePanelId,
                snapshot: snapshot
            )
        )
    }

    func testSidebarGitBranchesFollowLeftToRightSplitOrder() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftPanelId, branch: "main", isDirty: false)
        guard let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }
        workspace.updatePanelGitBranch(panelId: rightPanel.id, branch: "feature/sidebar", isDirty: true)

        let ordered = workspace.sidebarGitBranchesInDisplayOrder()
        XCTAssertEqual(ordered.map(\.branch), ["main", "feature/sidebar"])
        XCTAssertEqual(ordered.map(\.isDirty), [false, true])
    }

    func testUpdatingFocusedPanelGitBranchWithSameStateDoesNotRepublishWorkspace() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        // `Workspace` is `@Observable`, so it no longer exposes `objectWillChange`.
        // The signal these tests are about — "the workspace republished its
        // sidebar projection" — is the aggregate `sidebarObservationPublisher`
        // (which fans in the focused git-branch/PR state and de-dups), so observe
        // that directly. It is the same publisher the sibling
        // `testSidebarObservationPublisher…` test uses.
        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)
        let baselinePublishCount = publishCount

        XCTAssertGreaterThan(
            baselinePublishCount,
            0,
            "Expected the first focused branch update to publish workspace changes"
        )

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)

        XCTAssertEqual(
            publishCount,
            baselinePublishCount,
            "Expected identical focused branch refreshes to avoid extra workspace publishes"
        )
    }

    func testUpdatingFocusedPanelPullRequestWithSameStateDoesNotRepublishWorkspace() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "feature/sidebar-pr", isDirty: false)

        // See the git-branch test above: observe the aggregate sidebar projection
        // publisher rather than the retired `objectWillChange`.
        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        let pullRequestURL = URL(string: "https://github.com/manaflow-ai/cmux/pull/2388")!
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2388,
            label: "PR",
            url: pullRequestURL,
            status: .open,
            branch: "feature/sidebar-pr"
        )
        let baselinePublishCount = publishCount

        XCTAssertGreaterThan(
            baselinePublishCount,
            0,
            "Expected the first focused pull request update to publish workspace changes"
        )

        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2388,
            label: "PR",
            url: pullRequestURL,
            status: .open,
            branch: "feature/sidebar-pr"
        )

        XCTAssertEqual(
            publishCount,
            baselinePublishCount,
            "Expected identical focused pull request refreshes to avoid extra workspace publishes"
        )
    }

    func testSidebarObservationPublisherEmitsForFocusedGitBranchChangesOnlyOncePerState() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)
        let baselinePublishCount = publishCount
        XCTAssertGreaterThan(
            baselinePublishCount,
            0,
            "Expected focused git branch updates to invalidate sidebar rows"
        )

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)
        XCTAssertEqual(
            publishCount,
            baselinePublishCount,
            "Expected identical git metadata refreshes to be ignored by sidebar rows"
        )
    }

    @MainActor
    func testSidebarPullRequestsTrackFocusedPanelOnly() {
        let workspace = Workspace()
        guard let firstPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: firstPanelId),
              let secondPanel = workspace.newTerminalSurface(inPane: paneId, focus: false) else {
            XCTFail("Expected focused panel and a second panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: firstPanelId, branch: "main", isDirty: false)
        workspace.updatePanelGitBranch(panelId: secondPanel.id, branch: "feature/sidebar-pr", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: secondPanel.id,
            number: 1629,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/1629")!,
            status: .open
        )

        XCTAssertNil(workspace.pullRequest)
        XCTAssertTrue(
            workspace.sidebarPullRequestsInDisplayOrder().isEmpty,
            "Expected background panel PRs to stay hidden while the focused panel has no PR"
        )

        workspace.focusPanel(secondPanel.id)

        XCTAssertEqual(
            workspace.sidebarPullRequestsInDisplayOrder().map(\.number),
            [1629]
        )
    }

    func testSidebarOrderingUsesPaneOrderThenTabOrderWithBranchDeduping() {
        let workspace = Workspace()
        guard let leftFirstPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftFirstPanelId),
              let rightFirstPanel = workspace.newTerminalSplit(from: leftFirstPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightFirstPanel.id),
              let leftSecondPanel = workspace.newTerminalSurface(inPane: leftPaneId, focus: false),
              let rightSecondPanel = workspace.newTerminalSurface(inPane: rightPaneId, focus: false) else {
            XCTFail("Expected panes and panels for ordering test")
            return
        }

        XCTAssertTrue(workspace.reorderSurface(panelId: leftFirstPanelId, toIndex: 0))
        XCTAssertTrue(workspace.reorderSurface(panelId: leftSecondPanel.id, toIndex: 1))
        XCTAssertTrue(workspace.reorderSurface(panelId: rightFirstPanel.id, toIndex: 0))
        XCTAssertTrue(workspace.reorderSurface(panelId: rightSecondPanel.id, toIndex: 1))

        workspace.updatePanelGitBranch(panelId: leftFirstPanelId, branch: "main", isDirty: false)
        workspace.updatePanelGitBranch(panelId: leftSecondPanel.id, branch: "feature/left", isDirty: false)
        workspace.updatePanelGitBranch(panelId: rightFirstPanel.id, branch: "main", isDirty: true)
        workspace.updatePanelGitBranch(panelId: rightSecondPanel.id, branch: "feature/right", isDirty: false)

        XCTAssertEqual(
            workspace.sidebarOrderedPanelIds(),
            [leftFirstPanelId, leftSecondPanel.id, rightFirstPanel.id, rightSecondPanel.id]
        )

        let branches = workspace.sidebarGitBranchesInDisplayOrder()
        XCTAssertEqual(branches.map(\.branch), ["main", "feature/left", "feature/right"])
        XCTAssertEqual(branches.map(\.isDirty), [true, false, false])
    }

    func testSidebarBranchDirectoryEntriesStayStableAcrossFocusedSplitChanges() {
        let workspace = Workspace()
        let leftLiveDirectory = "/repo/left/live"
        let rightFocusedDirectory = "/repo/right/focused"
        let leftFocusedDirectory = "/repo/left/focused"
        let rightRequestedDirectory = "/repo/right/requested"

        guard let leftPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelDirectory(panelId: leftPanelId, directory: leftLiveDirectory)

        guard let rightSplitPanel = workspace.newTerminalSplit(
            from: leftPanelId,
            orientation: .horizontal,
            focus: false
        ),
        let rightPaneId = workspace.paneId(forPanelId: rightSplitPanel.id),
        let rightRequestedPanel = workspace.newTerminalSurface(
            inPane: rightPaneId,
            focus: false,
            workingDirectory: rightRequestedDirectory
        ) else {
            XCTFail("Expected right split panes for sidebar directory ordering test")
            return
        }

        let orderedPanelIds = workspace.sidebarOrderedPanelIds()
        XCTAssertEqual(orderedPanelIds, [leftPanelId, rightSplitPanel.id, rightRequestedPanel.id])

        workspace.currentDirectory = rightFocusedDirectory
        let entriesWhenRightLooksFocused = workspace.sidebarBranchDirectoryEntriesInDisplayOrder(
            orderedPanelIds: orderedPanelIds
        )

        workspace.currentDirectory = leftFocusedDirectory
        let entriesWhenLeftLooksFocused = workspace.sidebarBranchDirectoryEntriesInDisplayOrder(
            orderedPanelIds: orderedPanelIds
        )

        XCTAssertEqual(
            entriesWhenRightLooksFocused,
            entriesWhenLeftLooksFocused,
            "Expected sidebar directory ordering to ignore focused-workspace cwd churn when panel-specific directories are available"
        )
        XCTAssertEqual(
            entriesWhenRightLooksFocused.map(\.directory),
            [leftLiveDirectory, rightRequestedDirectory]
        )
    }

    func testRemoteSidebarDirectoryCanonicalizationDedupesTildeAndAbsoluteHomePaths() {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64007,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )

        let liveDirectory = "/home/remoteuser/project"
        let requestedDirectory = "~/project"

        guard let firstPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: firstPanelId),
              let requestedPanel = workspace.newTerminalSurface(
                  inPane: paneId,
                  focus: false,
                  workingDirectory: requestedDirectory
              ) else {
            XCTFail("Expected remote panels for sidebar directory canonicalization test")
            return
        }

        workspace.updatePanelDirectory(panelId: firstPanelId, directory: liveDirectory)

        let orderedPanelIds = workspace.sidebarOrderedPanelIds()
        XCTAssertEqual(orderedPanelIds, [firstPanelId, requestedPanel.id])

        XCTAssertEqual(
            workspace.sidebarDirectoriesInDisplayOrder(orderedPanelIds: orderedPanelIds),
            [liveDirectory]
        )
        XCTAssertEqual(
            workspace.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds).map(\.directory),
            [liveDirectory]
        )
    }

    func testSidebarDerivedCollectionsMatchWhenUsingPrecomputedPanelOrder() {
        let workspace = Workspace()
        guard let leftFirstPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftFirstPanelId),
              let rightFirstPanel = workspace.newTerminalSplit(from: leftFirstPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightFirstPanel.id),
              let leftSecondPanel = workspace.newTerminalSurface(inPane: leftPaneId, focus: false),
              let rightSecondPanel = workspace.newTerminalSurface(inPane: rightPaneId, focus: false) else {
            XCTFail("Expected panes and panels for precomputed ordering test")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftFirstPanelId, branch: "main", isDirty: false)
        workspace.updatePanelGitBranch(panelId: leftSecondPanel.id, branch: "feature/left", isDirty: true)
        workspace.updatePanelGitBranch(panelId: rightFirstPanel.id, branch: "release/right", isDirty: false)

        workspace.updatePanelDirectory(panelId: leftFirstPanelId, directory: "/repo/left/root")
        workspace.updatePanelDirectory(panelId: leftSecondPanel.id, directory: "/repo/left/feature")
        workspace.updatePanelDirectory(panelId: rightFirstPanel.id, directory: "/repo/right/root")
        workspace.updatePanelDirectory(panelId: rightSecondPanel.id, directory: "/repo/right/extra")

        workspace.updatePanelPullRequest(
            panelId: leftFirstPanelId,
            number: 101,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/101")!,
            status: .open
        )
        workspace.updatePanelPullRequest(
            panelId: rightFirstPanel.id,
            number: 18,
            label: "MR",
            url: URL(string: "https://gitlab.com/manaflow/cmux/-/merge_requests/18")!,
            status: .merged
        )

        let orderedPanelIds = workspace.sidebarOrderedPanelIds()

        XCTAssertEqual(
            workspace.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).map { "\($0.branch)|\($0.isDirty)" },
            workspace.sidebarGitBranchesInDisplayOrder().map { "\($0.branch)|\($0.isDirty)" }
        )
        XCTAssertEqual(
            workspace.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds),
            workspace.sidebarBranchDirectoryEntriesInDisplayOrder()
        )
        XCTAssertEqual(
            workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds),
            workspace.sidebarPullRequestsInDisplayOrder()
        )
    }

    func testClosingPaneDropsBranchesFromClosedSide() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected left/right split panes")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftPanelId, branch: "branch1", isDirty: false)
        workspace.updatePanelGitBranch(panelId: rightPanel.id, branch: "branch2", isDirty: false)

        XCTAssertEqual(workspace.sidebarGitBranchesInDisplayOrder().map(\.branch), ["branch1", "branch2"])
        XCTAssertTrue(workspace.bonsplitController.closePane(leftPaneId))
        XCTAssertEqual(workspace.sidebarGitBranchesInDisplayOrder().map(\.branch), ["branch2"])
    }

    // MARK: - Fork Conversation (new sibling tab)

    private func makeForkableClaudeSnapshot(
        sessionId: String = "019dad34-d218-7943-b81a-eddac5c87951",
        workingDirectory: String = "/tmp/fork repo"
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude"],
                workingDirectory: workingDirectory,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
    }

    private func makeForkableCodexSnapshot(
        sessionId: String = "019dad34-d218-7943-b81a-eddac5c87951",
        workingDirectory: String = "/tmp/fork repo"
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: workingDirectory,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
    }

    func testForkAgentConversationToNewTabCreatesSiblingTabWithForkStartupInput() throws {
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        let snapshot = makeForkableClaudeSnapshot()

        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversationToNewTab(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                anchorTabId: anchorTabId,
                paneId: sourcePaneId
            )
        )

        XCTAssertNotEqual(forkPanel.id, sourcePanelId)
        XCTAssertEqual(
            workspace.paneId(forPanelId: forkPanel.id),
            sourcePaneId,
            "Fork should land in the same pane as the source tab, not a split pane"
        )
        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            1,
            "Fork creates a sibling tab, not a new pane"
        )
        XCTAssertEqual(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).count,
            2,
            "Pane should now host both the source and forked tabs"
        )
        XCTAssertEqual(workspace.focusedPanelId, forkPanel.id, "Fork should focus the new tab")
        XCTAssertEqual(forkPanel.requestedWorkingDirectory, "/tmp/fork repo")
        XCTAssertEqual(
            forkPanel.surface.initialInput,
            snapshot.forkCommand.map { $0 + "\n" },
            "Forked tab should boot with the snapshot's --fork-session command"
        )
    }

    func testForkAgentConversationToNewTabPlacesForkImmediatelyRightOfAnchor() throws {
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))

        // Drop a second unrelated terminal tab to the right of the source so we can
        // verify the fork lands *between* the source and the unrelated tab, not at the
        // end of the strip.
        let trailingPanel = try XCTUnwrap(
            workspace.newTerminalSurface(inPane: sourcePaneId, focus: false)
        )
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: sourcePaneId).count, 2)

        let snapshot = makeForkableClaudeSnapshot()
        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversationToNewTab(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                anchorTabId: anchorTabId,
                paneId: sourcePaneId
            )
        )

        let tabIdsInOrder = workspace.bonsplitController.tabs(inPane: sourcePaneId).map(\.id)
        let sourceTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        let forkTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(forkPanel.id))
        let trailingTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(trailingPanel.id))
        XCTAssertEqual(
            tabIdsInOrder,
            [sourceTabId, forkTabId, trailingTabId],
            "Fork should be inserted immediately to the right of its source tab"
        )
    }

    func testCanForkAgentConversationFromPanelReturnsTrueForRestoredClaudeSnapshot() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertFalse(
            workspace.canForkAgentConversationFromPanel(panelId),
            "Vanilla shell tab without an agent snapshot should not advertise fork"
        )

        workspace.setRestoredAgentSnapshotForTesting(makeForkableClaudeSnapshot(), panelId: panelId)
        XCTAssertTrue(
            workspace.canForkAgentConversationFromPanel(panelId),
            "Tab hosting a restored Claude snapshot should advertise fork"
        )
    }

    func testCanForkAgentConversationFromPanelReturnsFalseForUnknownPanel() {
        let workspace = Workspace()
        XCTAssertFalse(workspace.canForkAgentConversationFromPanel(UUID()))
    }

    func testForkConversationDefaultSettingFallsBackToRight() throws {
        let suiteName = "cmux.forkConversationDefault.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            AgentConversationForkDestination.configuredDefault(defaults: defaults),
            .right,
            "Missing setting should use the product default"
        )

        defaults.set(AgentConversationForkDestination.newTab.rawValue, forKey: AgentConversationForkDestination.defaultDestinationDefaultsKey)
        XCTAssertEqual(AgentConversationForkDestination.configuredDefault(defaults: defaults), .newTab)

        defaults.set("unsupported", forKey: AgentConversationForkDestination.defaultDestinationDefaultsKey)
        XCTAssertEqual(
            AgentConversationForkDestination.configuredDefault(defaults: defaults),
            .right,
            "Invalid settings file values should fall back to the product default"
        )
    }

    func testForkConversationContextMenuDefaultActionWorksForCodexSnapshot() throws {
        // Parity coverage with the Claude path: Codex sessions are also `.supportedWithoutProbe`
        // and should reach the default right-split path through the context-menu dispatcher.
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: AgentConversationForkDestination.defaultDestinationDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: AgentConversationForkDestination.defaultDestinationDefaultsKey)
            } else {
                defaults.removeObject(forKey: AgentConversationForkDestination.defaultDestinationDefaultsKey)
            }
        }
        defaults.removeObject(forKey: AgentConversationForkDestination.defaultDestinationDefaultsKey)

        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        let snapshot = makeForkableCodexSnapshot()
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelId)

        XCTAssertTrue(workspace.canForkAgentConversationFromPanel(sourcePanelId))

        let anchorTab = try XCTUnwrap(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).first { $0.id == anchorTabId }
        )

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .forkConversation,
            for: anchorTab,
            inPane: sourcePaneId
        )

        let forkPanelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertNotEqual(forkPanelId, sourcePanelId, "Codex fork should focus the new split")
        let forkPanel = try XCTUnwrap(workspace.terminalPanel(for: forkPanelId))
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 2)
        XCTAssertEqual(
            forkPanel.surface.initialInput,
            snapshot.forkCommand.map { $0 + "\n" },
            "Codex fork split should boot with the Codex --fork-session command"
        )
        let split = try rootSplit(in: workspace)
        let sourcePaneUUID = sourcePaneId.id.uuidString
        let forkPaneUUID = try XCTUnwrap(workspace.paneId(forPanelId: forkPanelId)).id.uuidString
        XCTAssertEqual(split.orientation, "horizontal")
        XCTAssertEqual(try paneId(in: split.first), sourcePaneUUID)
        XCTAssertEqual(try paneId(in: split.second), forkPaneUUID)
    }

    func testForkConversationContextMenuNewTabActionCreatesSiblingTab() throws {
        // Drive the same code path the bonsplit context menu triggers, end-to-end,
        // to lock in that the menu wiring stays connected.
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        workspace.setRestoredAgentSnapshotForTesting(makeForkableClaudeSnapshot(), panelId: sourcePanelId)

        let tabs = workspace.bonsplitController.tabs(inPane: sourcePaneId)
        let anchorTab = try XCTUnwrap(tabs.first { $0.id == anchorTabId })

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .forkConversationNewTab,
            for: anchorTab,
            inPane: sourcePaneId
        )

        XCTAssertEqual(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).count,
            2,
            "Fork Conversation New Tab context action should spawn a sibling tab"
        )
        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            1,
            "Fork Conversation New Tab should not create a split pane"
        )
    }

    func testForkConversationContextMenuPrimaryActionUsesConfiguredDefault() throws {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: AgentConversationForkDestination.defaultDestinationDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: AgentConversationForkDestination.defaultDestinationDefaultsKey)
            } else {
                defaults.removeObject(forKey: AgentConversationForkDestination.defaultDestinationDefaultsKey)
            }
        }
        defaults.set(AgentConversationForkDestination.newTab.rawValue, forKey: AgentConversationForkDestination.defaultDestinationDefaultsKey)

        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        workspace.setRestoredAgentSnapshotForTesting(makeForkableClaudeSnapshot(), panelId: sourcePanelId)

        let anchorTab = try XCTUnwrap(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).first { $0.id == anchorTabId }
        )

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .forkConversation,
            for: anchorTab,
            inPane: sourcePaneId
        )

        XCTAssertEqual(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).count,
            2,
            "Configured default should control the primary Fork Conversation context action"
        )
        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            1,
            "Configured New Tab default should keep the fork in the source pane"
        )
    }
}


final class WorkspaceMountPolicyTests: XCTestCase {
    func testDefaultPolicyMountsOnlySelectedWorkspace() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPlan(
            current: [a],
            selected: b,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: WorkspaceMountPlan.maxMountedWorkspaces
        ).mountedWorkspaceIds

        XCTAssertEqual(next, [b])
    }

    func testSelectedWorkspaceMovesToFrontAndMountCountIsBounded() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let orderedTabIds: [UUID] = [a, b, c]

        let next = WorkspaceMountPlan(
            current: [a, b, c],
            selected: c,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 2
        ).mountedWorkspaceIds

        XCTAssertEqual(next, [c, a])
    }

    func testMissingWorkspacesArePruned() {
        let a = UUID()
        let b = UUID()

        let next = WorkspaceMountPlan(
            current: [b, a],
            selected: nil,
            pinnedIds: [],
            orderedTabIds: [a],
            isCycleHot: false,
            maxMounted: 2
        ).mountedWorkspaceIds

        XCTAssertEqual(next, [a])
    }

    func testSelectedWorkspaceIsInsertedWhenAbsentFromCurrentCache() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPlan(
            current: [a],
            selected: b,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 2
        ).mountedWorkspaceIds

        XCTAssertEqual(next, [b, a])
    }

    func testMaxMountedIsClampedToAtLeastOne() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPlan(
            current: [a, b],
            selected: nil,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 0
        ).mountedWorkspaceIds

        XCTAssertEqual(next, [a])
    }

    func testCycleHotModeKeepsOnlySelectedWhenNoPinnedHandoff() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let orderedTabIds: [UUID] = [a, b, c, d]

        let next = WorkspaceMountPlan(
            current: [a],
            selected: c,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: true,
            maxMounted: WorkspaceMountPlan.maxMountedWorkspacesDuringCycle
        ).mountedWorkspaceIds

        XCTAssertEqual(next, [c])
    }

    func testCycleHotModeRespectsMaxMountedLimit() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let orderedTabIds: [UUID] = [a, b, c]

        let next = WorkspaceMountPlan(
            current: [a, b, c],
            selected: b,
            pinnedIds: [],
            orderedTabIds: orderedTabIds,
            isCycleHot: true,
            maxMounted: 2
        ).mountedWorkspaceIds

        XCTAssertEqual(next, [b])
    }

    func testPinnedIdsAreRetainedAcrossReconcile() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let orderedTabIds: [UUID] = [a, b, c]

        let next = WorkspaceMountPlan(
            current: [a],
            selected: c,
            pinnedIds: [a],
            orderedTabIds: orderedTabIds,
            isCycleHot: false,
            maxMounted: 2
        ).mountedWorkspaceIds

        XCTAssertEqual(next, [c, a])
    }

    func testCycleHotModeKeepsRetiringWorkspaceWhenPinned() {
        let a = UUID()
        let b = UUID()
        let orderedTabIds: [UUID] = [a, b]

        let next = WorkspaceMountPlan(
            current: [a],
            selected: b,
            pinnedIds: [a],
            orderedTabIds: orderedTabIds,
            isCycleHot: true,
            maxMounted: WorkspaceMountPlan.maxMountedWorkspacesDuringCycle
        ).mountedWorkspaceIds

        XCTAssertEqual(next, [b, a])
    }
}


@MainActor
final class SidebarWorkspaceShortcutHintMetricsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SidebarWorkspaceShortcutHintMetrics().resetCacheForTesting()
    }

    override func tearDown() {
        SidebarWorkspaceShortcutHintMetrics().resetCacheForTesting()
        super.tearDown()
    }

    func testHintWidthCachesRepeatedMeasurements() {
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics().measurementCountForTesting(), 0)

        let first = SidebarWorkspaceShortcutHintMetrics().hintWidth(for: "⌘1")
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics().measurementCountForTesting(), 1)

        let second = SidebarWorkspaceShortcutHintMetrics().hintWidth(for: "⌘1")
        XCTAssertEqual(second, first)
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics().measurementCountForTesting(), 1)

        _ = SidebarWorkspaceShortcutHintMetrics().hintWidth(for: "⌘2")
        XCTAssertEqual(SidebarWorkspaceShortcutHintMetrics().measurementCountForTesting(), 2)
    }

    func testSlotWidthAppliesMinimumAndDebugInset() {
        let nilLabelWidth = SidebarWorkspaceShortcutHintMetrics().slotWidth(label: nil, debugXOffset: 999)
        XCTAssertEqual(nilLabelWidth, 28)

        let base = SidebarWorkspaceShortcutHintMetrics().slotWidth(label: "⌘1", debugXOffset: 0)
        let widened = SidebarWorkspaceShortcutHintMetrics().slotWidth(label: "⌘1", debugXOffset: 10)
        XCTAssertGreaterThan(widened, base)
    }
}

final class ExtensionWorktreePrototypeTests: XCTestCase {
    func testPipeOutputCollectorDrainsBufferedOutputOnFinish() async throws {
        let pipe = Pipe()
        let collector = CmuxExtensionPipeOutputCollector(fileHandle: pipe.fileHandleForReading)

        pipe.fileHandleForWriting.write(Data("exclude-path\n".utf8))
        try pipe.fileHandleForWriting.close()

        let output = await collector.finish()

        XCTAssertEqual(String(data: output, encoding: .utf8), "exclude-path\n")
    }

    func testCreateWorktreeKeepsCmuxDirectoryLocallyIgnored() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-worktree-prototype-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("Project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        _ = try runGit(["init"], in: projectRoot)
        try "hello\n".write(to: projectRoot.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try runGit(["add", "README.md"], in: projectRoot)
        _ = try runGit([
            "-c", "user.name=cmux Test",
            "-c", "user.email=cmux@example.invalid",
            "commit",
            "-m",
            "initial"
        ], in: projectRoot)

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(projectRootPath: projectRoot.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.worktreePath))
        XCTAssertTrue(result.workspaceTitle.hasPrefix("cmux-sidebar-"))
        let status = try runGit(["status", "--short", "--untracked-files=all"], in: projectRoot)
        XCTAssertEqual(status.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(output)")
            throw NSError(domain: "ExtensionWorktreePrototypeTests", code: Int(process.terminationStatus))
        }
        return output
    }
}
