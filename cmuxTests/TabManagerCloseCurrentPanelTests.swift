import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import CmuxGit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


let lastSurfaceCloseShortcutDefaultsKey = "closeWorkspaceOnLastSurfaceShortcut"

@MainActor
final class TabManagerCloseCurrentPanelTests: XCTestCase {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"

    func testCloseCurrentPanelHonorsWarnBeforeClosingTabDisabledFromCmuxJSON() throws {
        try assertCloseCurrentPanelConfirmation(
            warnBeforeClosingTab: false,
            expectedPromptCount: 0,
            expectedPanelClosed: true
        )
    }

    func testCloseCurrentPanelHonorsWarnBeforeClosingTabEnabledFromCmuxJSON() throws {
        try assertCloseCurrentPanelConfirmation(
            warnBeforeClosingTab: true,
            expectedPromptCount: 1,
            expectedPanelClosed: false
        )
    }

    func testCloseCurrentPanelWarnBeforeClosingTabDefaultsToEnabledWhenUnset() throws {
        try assertCloseCurrentPanelConfirmation(
            warnBeforeClosingTab: nil,
            expectedPromptCount: 1,
            expectedPanelClosed: false
        )
    }

    func testTabCloseButtonWarningHonorsCmuxJSON() throws {
        try withCloseTabConfig(warnBeforeClosingTabXButton: true) {
            XCTAssertTrue(
                CloseTabConfirmationPolicy.shouldConfirm(
                    requiresConfirmation: false,
                    source: .tabCloseButton
                )
            )
        }
    }

    func testHideTabCloseButtonHonorsCmuxJSON() throws {
        try withCloseTabConfig(hideTabCloseButton: true) {
            let manager = TabManager()
            guard let workspace = manager.selectedWorkspace else {
                XCTFail("Expected selected workspace")
                return
            }

            XCTAssertFalse(workspace.bonsplitController.configuration.allowCloseTabs)
        }
    }

    func testTabCloseButtonWarningDefaultsOffForCleanPanel() throws {
        try assertTabCloseButtonConfirmation(
            warnBeforeClosingTab: nil,
            warnBeforeClosingTabXButton: nil,
            panelNeedsConfirmation: false,
            expectedPromptCount: 0,
            expectedPanelClosed: true
        )
    }

    func testTabCloseButtonWarningPromptsWhenEnabledForCleanPanel() throws {
        try assertTabCloseButtonConfirmation(
            warnBeforeClosingTab: nil,
            warnBeforeClosingTabXButton: true,
            panelNeedsConfirmation: false,
            expectedPromptCount: 1,
            expectedPanelClosed: false
        )
    }

    func testMiddleClickCloseDoesNotUseXButtonWarning() throws {
        try assertTabCloseButtonConfirmation(
            warnBeforeClosingTab: nil,
            warnBeforeClosingTabXButton: true,
            panelNeedsConfirmation: false,
            marksTabCloseButtonSource: false,
            expectedPromptCount: 0,
            expectedPanelClosed: true
        )
    }

    func testTabCloseButtonPreservesExistingDirtyPanelWarningWhenXButtonSettingIsOff() throws {
        try assertTabCloseButtonConfirmation(
            warnBeforeClosingTab: nil,
            warnBeforeClosingTabXButton: nil,
            panelNeedsConfirmation: true,
            expectedPromptCount: 1,
            expectedPanelClosed: false
        )
    }

    func testHideTabCloseButtonDisablesBonsplitTabCloseAffordances() throws {
        try withCloseTabUserDefaults(hideTabCloseButton: true) {
            let manager = TabManager()
            guard let workspace = manager.selectedWorkspace else {
                XCTFail("Expected selected workspace")
                return
            }

            XCTAssertFalse(workspace.bonsplitController.configuration.allowCloseTabs)
        }
    }

    func testTabCloseButtonVisibilityRefreshesFromDefaults() throws {
        try withCloseTabUserDefaults(hideTabCloseButton: false) {
            let defaults = UserDefaults.standard
            let manager = TabManager()
            guard let workspace = manager.selectedWorkspace else {
                XCTFail("Expected selected workspace")
                return
            }

            XCTAssertTrue(workspace.bonsplitController.configuration.allowCloseTabs)
            defaults.set(true, forKey: CloseTabWarningSettings.hideTabCloseButtonKey)
            manager.refreshTabCloseButtonVisibility()

            XCTAssertFalse(workspace.bonsplitController.configuration.allowCloseTabs)
        }
    }

    func testCloseCurrentPanelHonorsWarnBeforeClosingTabDisabledForPinnedWorkspaceLastSurface() throws {
        try assertPinnedWorkspaceLastSurfaceConfirmation(
            warnBeforeClosingTab: false,
            expectedPromptCount: 0,
            expectedWorkspaceClosed: true
        )
    }

    func testCloseCurrentPanelHonorsWarnBeforeClosingTabEnabledForPinnedWorkspaceLastSurface() throws {
        try assertPinnedWorkspaceLastSurfaceConfirmation(
            warnBeforeClosingTab: true,
            expectedPromptCount: 1,
            expectedWorkspaceClosed: false
        )
    }

    func testRuntimeCloseSkipsConfirmationWhenShellReportsPromptIdle() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected selected workspace and focused terminal panel")
            return
        }

        terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(true)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return false
        }

        manager.closeRuntimeSurfaceWithConfirmation(tabId: workspace.id, surfaceId: panelId)
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(promptCount, 0, "Runtime closes should honor prompt-idle shell state")
        XCTAssertNil(workspace.panels[panelId], "Expected the original panel to close")
        XCTAssertEqual(workspace.panels.count, 1, "Expected a replacement surface after closing the last panel")
    }

    func testRuntimeClosePromptsWhenShellReportsRunningCommand() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected selected workspace and focused terminal panel")
            return
        }

        terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(false)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return false
        }

        manager.closeRuntimeSurfaceWithConfirmation(tabId: workspace.id, surfaceId: panelId)

        XCTAssertEqual(promptCount, 1, "Running commands should still require confirmation")
        XCTAssertNotNil(workspace.panels[panelId], "Prompt rejection should keep the original panel open")
    }

    func testCloseCurrentPanelClosesWorkspaceWhenItOwnsTheLastSurface() {
        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let secondWorkspace = manager.addWorkspace()
        manager.selectWorkspace(secondWorkspace)

        guard let secondPanelId = secondWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertEqual(secondWorkspace.panels.count, 1)

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertNil(secondWorkspace.panels[secondPanelId])
        XCTAssertTrue(secondWorkspace.panels.isEmpty)
    }

    func testCloseCurrentPanelPromptsBeforeClosingPinnedWorkspaceLastSurface() {
        let manager = TabManager()
        _ = manager.tabs[0]
        let pinnedWorkspace = manager.addWorkspace()
        manager.setPinned(pinnedWorkspace, pinned: true)
        manager.selectWorkspace(pinnedWorkspace)

        guard let pinnedPanelId = pinnedWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in pinned workspace")
            return
        }

        XCTAssertEqual(manager.selectedTabId, pinnedWorkspace.id)
        XCTAssertEqual(pinnedWorkspace.panels.count, 1)

        var prompts: [(title: String, message: String, acceptCmdD: Bool)] = []
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            prompts.append((title, message, acceptCmdD))
            return false
        }

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closePinnedWorkspace.title", defaultValue: "Close pinned workspace?")
        )
        XCTAssertEqual(
            prompts.first?.message,
            String(
                localized: "dialog.closePinnedWorkspace.message",
                defaultValue: "This workspace is pinned. Closing it will close the workspace and all of its panels."
            )
        )
        XCTAssertEqual(prompts.first?.acceptCmdD, false)
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == pinnedWorkspace.id }))
        XCTAssertEqual(manager.selectedTabId, pinnedWorkspace.id)
        XCTAssertNotNil(pinnedWorkspace.panels[pinnedPanelId])
        XCTAssertEqual(pinnedWorkspace.panels.count, 1)
    }

    func testCloseCurrentPanelClosesPinnedWorkspaceAfterConfirmation() {
        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let pinnedWorkspace = manager.addWorkspace()
        manager.setPinned(pinnedWorkspace, pinned: true)
        manager.selectWorkspace(pinnedWorkspace)

        guard let pinnedPanelId = pinnedWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in pinned workspace")
            return
        }

        manager.confirmCloseHandler = { _, _, _ in true }

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertNil(pinnedWorkspace.panels[pinnedPanelId])
        XCTAssertTrue(pinnedWorkspace.panels.isEmpty)
    }

    func testCloseCurrentPanelKeepsWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: lastSurfaceCloseShortcutDefaultsKey)
        defaults.set(false, forKey: lastSurfaceCloseShortcutDefaultsKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: lastSurfaceCloseShortcutDefaultsKey)
            } else {
                defaults.removeObject(forKey: lastSurfaceCloseShortcutDefaultsKey)
            }
        }

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace and focused panel")
            return
        }

        let initialWorkspaceId = workspace.id

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTabId, initialWorkspaceId)
        XCTAssertEqual(manager.tabs.first?.id, initialWorkspaceId)
        XCTAssertNil(workspace.panels[initialPanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(workspace.focusedPanelId, initialPanelId)
    }

    func testClosePanelButtonClosesWorkspaceWhenItOwnsTheLastSurface() {
        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let secondWorkspace = manager.addWorkspace()
        manager.selectWorkspace(secondWorkspace)

        guard let secondPanelId = secondWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertEqual(secondWorkspace.panels.count, 1)

        guard let secondSurfaceId = secondWorkspace.surfaceIdFromPanelId(secondPanelId) else {
            XCTFail("Expected bonsplit surface ID for focused panel")
            return
        }

        secondWorkspace.markExplicitClose(surfaceId: secondSurfaceId)
        XCTAssertFalse(secondWorkspace.closePanel(secondPanelId))
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertNil(secondWorkspace.panels[secondPanelId])
        XCTAssertTrue(secondWorkspace.panels.isEmpty)
    }

    func testClosePanelButtonStillClosesWorkspaceWhenKeepWorkspaceOpenPreferenceIsEnabled() {
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: lastSurfaceCloseShortcutDefaultsKey)
        defaults.set(false, forKey: lastSurfaceCloseShortcutDefaultsKey)
        defer {
            if let originalSetting {
                defaults.set(originalSetting, forKey: lastSurfaceCloseShortcutDefaultsKey)
            } else {
                defaults.removeObject(forKey: lastSurfaceCloseShortcutDefaultsKey)
            }
        }

        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let secondWorkspace = manager.addWorkspace()
        manager.selectWorkspace(secondWorkspace)

        guard let secondPanelId = secondWorkspace.focusedPanelId else {
            XCTFail("Expected focused panel in selected workspace")
            return
        }

        guard let secondSurfaceId = secondWorkspace.surfaceIdFromPanelId(secondPanelId) else {
            XCTFail("Expected bonsplit surface ID for focused panel")
            return
        }

        secondWorkspace.markExplicitClose(surfaceId: secondSurfaceId)
        XCTAssertFalse(secondWorkspace.closePanel(secondPanelId))
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertNil(secondWorkspace.panels[secondPanelId])
        XCTAssertTrue(secondWorkspace.panels.isEmpty)
    }

    func testGenericClosePanelKeepsWorkspaceOpenWithoutExplicitCloseMarker() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace and focused panel")
            return
        }

        let initialWorkspaceId = workspace.id
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(workspace.panels.count, 1)

        XCTAssertTrue(workspace.closePanel(initialPanelId))
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTabId, initialWorkspaceId)
        XCTAssertEqual(manager.tabs.first?.id, initialWorkspaceId)
        XCTAssertNil(workspace.panels[initialPanelId])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNotEqual(workspace.focusedPanelId, initialPanelId)
    }

    func testCloseCurrentPanelIgnoresStaleSurfaceId() {
        let manager = TabManager()
        let firstWorkspace = manager.tabs[0]
        let secondWorkspace = manager.addWorkspace()

        manager.closePanelWithConfirmation(tabId: secondWorkspace.id, surfaceId: UUID())

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id, secondWorkspace.id])
    }

    func testCloseCurrentPanelClearsNotificationsForClosedSurface() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let workspace = manager.selectedWorkspace,
              let initialPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace and focused panel")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: initialPanelId,
            title: "Unread",
            subtitle: "",
            body: ""
        )
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: initialPanelId))

        manager.closeCurrentPanelWithConfirmation()
        drainMainQueue()
        drainMainQueue()

        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: initialPanelId))
    }

    private func assertCloseCurrentPanelConfirmation(
        warnBeforeClosingTab: Bool?,
        expectedPromptCount: Int,
        expectedPanelClosed: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try withWarnBeforeClosingTabConfig(warnBeforeClosingTab) {
            let manager = TabManager()
            guard let workspace = manager.selectedWorkspace,
                  let paneId = workspace.bonsplitController.focusedPaneId,
                  let initialPanelId = workspace.focusedPanelId,
                  let initialTerminalPanel = workspace.terminalPanel(for: initialPanelId),
                  workspace.newTerminalSurface(inPane: paneId, focus: false) != nil else {
                XCTFail("Expected workspace with two terminal surfaces", file: file, line: line)
                return
            }
            workspace.focusPanel(initialPanelId)
            initialTerminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(true)

            var promptCount = 0
            manager.confirmCloseHandler = { _, _, _ in
                promptCount += 1
                return false
            }

            manager.closeCurrentPanelWithConfirmation()
            drainMainQueue()
            drainMainQueue()
            drainMainQueue()

            XCTAssertEqual(promptCount, expectedPromptCount, file: file, line: line)
            if expectedPanelClosed {
                XCTAssertNil(workspace.panels[initialPanelId], file: file, line: line)
            } else {
                XCTAssertNotNil(workspace.panels[initialPanelId], file: file, line: line)
            }
        }
    }

    private func assertPinnedWorkspaceLastSurfaceConfirmation(
        warnBeforeClosingTab: Bool?,
        expectedPromptCount: Int,
        expectedWorkspaceClosed: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try withWarnBeforeClosingTabConfig(warnBeforeClosingTab) {
            let manager = TabManager()
            let firstWorkspace = manager.tabs[0]
            let pinnedWorkspace = manager.addWorkspace()
            manager.setPinned(pinnedWorkspace, pinned: true)
            manager.selectWorkspace(pinnedWorkspace)

            guard let pinnedPanelId = pinnedWorkspace.focusedPanelId else {
                XCTFail("Expected focused panel in pinned workspace", file: file, line: line)
                return
            }

            var promptCount = 0
            manager.confirmCloseHandler = { _, _, _ in
                promptCount += 1
                return false
            }

            manager.closeCurrentPanelWithConfirmation()
            drainMainQueue()
            drainMainQueue()
            drainMainQueue()

            XCTAssertEqual(promptCount, expectedPromptCount, file: file, line: line)
            if expectedWorkspaceClosed {
                XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id], file: file, line: line)
                XCTAssertNil(pinnedWorkspace.panels[pinnedPanelId], file: file, line: line)
            } else {
                XCTAssertTrue(manager.tabs.contains(where: { $0.id == pinnedWorkspace.id }), file: file, line: line)
                XCTAssertNotNil(pinnedWorkspace.panels[pinnedPanelId], file: file, line: line)
            }
        }
    }

    private func assertTabCloseButtonConfirmation(
        warnBeforeClosingTab: Bool?,
        warnBeforeClosingTabXButton: Bool?,
        panelNeedsConfirmation: Bool,
        marksTabCloseButtonSource: Bool = true,
        expectedPromptCount: Int,
        expectedPanelClosed: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try withCloseTabUserDefaults(
            warnBeforeClosingTab: warnBeforeClosingTab,
            warnBeforeClosingTabXButton: warnBeforeClosingTabXButton,
            hideTabCloseButton: false
        ) {
            let manager = TabManager()
            guard let workspace = manager.selectedWorkspace,
                  let paneId = workspace.bonsplitController.focusedPaneId,
                  let initialPanelId = workspace.focusedPanelId,
                  let initialTerminalPanel = workspace.terminalPanel(for: initialPanelId),
                  workspace.newTerminalSurface(inPane: paneId, focus: false) != nil,
                  let initialSurfaceId = workspace.surfaceIdFromPanelId(initialPanelId) else {
                XCTFail("Expected workspace with two terminal surfaces", file: file, line: line)
                return
            }
            workspace.focusPanel(initialPanelId)
            initialTerminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(panelNeedsConfirmation)

            var promptCount = 0
            manager.confirmCloseHandler = { _, _, _ in
                promptCount += 1
                return false
            }

            if marksTabCloseButtonSource {
                workspace.markTabCloseButtonClose(surfaceId: initialSurfaceId)
            } else {
                workspace.markExplicitClose(surfaceId: initialSurfaceId)
            }
            _ = workspace.bonsplitController.closeTab(initialSurfaceId)
            drainMainQueue()
            drainMainQueue()
            drainMainQueue()

            XCTAssertEqual(promptCount, expectedPromptCount, file: file, line: line)
            if expectedPanelClosed {
                XCTAssertNil(workspace.panels[initialPanelId], file: file, line: line)
            } else {
                XCTAssertNotNil(workspace.panels[initialPanelId], file: file, line: line)
            }
        }
    }

    private func withCloseTabUserDefaults(
        warnBeforeClosingTab: Bool? = nil,
        warnBeforeClosingTabXButton: Bool? = nil,
        hideTabCloseButton: Bool? = nil,
        run: () throws -> Void
    ) throws {
        let defaults = UserDefaults.standard
        let originalWarnBeforeClosingTab = defaults.object(forKey: CloseTabWarningSettings.warnBeforeClosingTabKey)
        let originalWarnBeforeClosingTabXButton = defaults.object(forKey: CloseTabWarningSettings.warnBeforeClosingTabXButtonKey)
        let originalHideTabCloseButton = defaults.object(forKey: CloseTabWarningSettings.hideTabCloseButtonKey)
        defer {
            restore(originalWarnBeforeClosingTab, forKey: CloseTabWarningSettings.warnBeforeClosingTabKey, defaults: defaults)
            restore(originalWarnBeforeClosingTabXButton, forKey: CloseTabWarningSettings.warnBeforeClosingTabXButtonKey, defaults: defaults)
            restore(originalHideTabCloseButton, forKey: CloseTabWarningSettings.hideTabCloseButtonKey, defaults: defaults)
        }

        setOrRemove(warnBeforeClosingTab, forKey: CloseTabWarningSettings.warnBeforeClosingTabKey, defaults: defaults)
        setOrRemove(warnBeforeClosingTabXButton, forKey: CloseTabWarningSettings.warnBeforeClosingTabXButtonKey, defaults: defaults)
        setOrRemove(hideTabCloseButton, forKey: CloseTabWarningSettings.hideTabCloseButtonKey, defaults: defaults)

        try run()
    }

    private func setOrRemove(_ value: Bool?, forKey key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func restore(_ value: Any?, forKey key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func withWarnBeforeClosingTabConfig(
        _ warnBeforeClosingTab: Bool?,
        run: () throws -> Void
    ) throws {
        try withCloseTabConfig(warnBeforeClosingTab: warnBeforeClosingTab, run: run)
    }

    private func withCloseTabConfig(
        warnBeforeClosingTab: Bool? = nil,
        warnBeforeClosingTabXButton: Bool? = nil,
        hideTabCloseButton: Bool? = nil,
        run: () throws -> Void
    ) throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        let defaults = UserDefaults.standard
        let originalWarnBeforeClosingTab = defaults.object(forKey: CloseTabWarningSettings.warnBeforeClosingTabKey)
        let originalWarnBeforeClosingTabXButton = defaults.object(forKey: CloseTabWarningSettings.warnBeforeClosingTabXButtonKey)
        let originalHideTabCloseButton = defaults.object(forKey: CloseTabWarningSettings.hideTabCloseButtonKey)
        let originalBackups = defaults.object(forKey: settingsFileBackupsDefaultsKey)
        defaults.removeObject(forKey: CloseTabWarningSettings.warnBeforeClosingTabKey)
        defaults.removeObject(forKey: CloseTabWarningSettings.warnBeforeClosingTabXButtonKey)
        defaults.removeObject(forKey: CloseTabWarningSettings.hideTabCloseButtonKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            restore(originalWarnBeforeClosingTab, forKey: CloseTabWarningSettings.warnBeforeClosingTabKey, defaults: defaults)
            restore(originalWarnBeforeClosingTabXButton, forKey: CloseTabWarningSettings.warnBeforeClosingTabXButtonKey, defaults: defaults)
            restore(originalHideTabCloseButton, forKey: CloseTabWarningSettings.hideTabCloseButtonKey, defaults: defaults)
            if let originalBackups {
                defaults.set(originalBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WarnBeforeClosingTabTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        let settingLines = [
            warnBeforeClosingTab.map { #"    "warnBeforeClosingTab": \#($0)"# },
            warnBeforeClosingTabXButton.map { #"    "warnBeforeClosingTabXButton": \#($0)"# },
            hideTabCloseButton.map { #"    "hideTabCloseButton": \#($0)"# },
        ].compactMap { $0 }
        let appBody = settingLines.isEmpty ? "" : "\n\(settingLines.joined(separator: ",\n"))\n  "
        try """
        {
          "app": {\(appBody)}
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        try run()
    }
}


