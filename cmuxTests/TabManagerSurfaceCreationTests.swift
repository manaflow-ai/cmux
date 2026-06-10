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


@MainActor
final class TabManagerSurfaceCreationTests: XCTestCase {
    func testFocusTextBoxOnNewTerminalsDefaultAppliesToNewWorkspaceAndTerminalSurfaces() {
        let defaults = UserDefaults.standard
        let showKey = TerminalTextBoxInputSettings.showOnNewTerminalsKey
        let focusKey = TerminalTextBoxInputSettings.focusOnNewTerminalsKey
        let previousShowValue = defaults.object(forKey: showKey)
        let previousFocusValue = defaults.object(forKey: focusKey)
        defer {
            if let previousShowValue {
                defaults.set(previousShowValue, forKey: showKey)
            } else {
                defaults.removeObject(forKey: showKey)
            }
            if let previousFocusValue {
                defaults.set(previousFocusValue, forKey: focusKey)
            } else {
                defaults.removeObject(forKey: focusKey)
            }
        }

        defaults.set(false, forKey: showKey)
        defaults.set(true, forKey: focusKey)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanel = workspace.focusedTerminalPanel,
              let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected initial terminal workspace")
            return
        }

        XCTAssertTrue(initialPanel.isTextBoxActive)
        XCTAssertEqual(initialPanel.preferredFocusIntentForActivation(), .terminal(.textBoxInput))

        guard let newTabPanel = workspace.newTerminalSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected new terminal tab")
            return
        }

        XCTAssertTrue(newTabPanel.isTextBoxActive)
        XCTAssertEqual(newTabPanel.preferredFocusIntentForActivation(), .terminal(.textBoxInput))

        guard let splitPanel = workspace.newTerminalSplit(from: newTabPanel.id, orientation: .horizontal) else {
            XCTFail("Expected new terminal split")
            return
        }

        XCTAssertTrue(splitPanel.isTextBoxActive)
        XCTAssertEqual(splitPanel.preferredFocusIntentForActivation(), .terminal(.textBoxInput))
    }

    func testShowTextBoxOnNewTerminalsDefaultShowsWithoutStealingFocus() {
        let defaults = UserDefaults.standard
        let showKey = TerminalTextBoxInputSettings.showOnNewTerminalsKey
        let focusKey = TerminalTextBoxInputSettings.focusOnNewTerminalsKey
        let previousShowValue = defaults.object(forKey: showKey)
        let previousFocusValue = defaults.object(forKey: focusKey)
        defer {
            if let previousShowValue {
                defaults.set(previousShowValue, forKey: showKey)
            } else {
                defaults.removeObject(forKey: showKey)
            }
            if let previousFocusValue {
                defaults.set(previousFocusValue, forKey: focusKey)
            } else {
                defaults.removeObject(forKey: focusKey)
            }
        }

        defaults.set(true, forKey: showKey)
        defaults.set(false, forKey: focusKey)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanel = workspace.focusedTerminalPanel,
              let paneId = workspace.bonsplitController.focusedPaneId,
              let newTabPanel = workspace.newTerminalSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected initial and new terminal panels")
            return
        }

        XCTAssertTrue(initialPanel.isTextBoxActive)
        XCTAssertNotEqual(initialPanel.preferredFocusIntentForActivation(), .terminal(.textBoxInput))
        XCTAssertTrue(newTabPanel.isTextBoxActive)
        XCTAssertNotEqual(newTabPanel.preferredFocusIntentForActivation(), .terminal(.textBoxInput))
    }

    func testFocusTextBoxOnNewTerminalsDefaultLeavesNewTerminalsHiddenWhenDisabled() {
        let defaults = UserDefaults.standard
        let showKey = TerminalTextBoxInputSettings.showOnNewTerminalsKey
        let focusKey = TerminalTextBoxInputSettings.focusOnNewTerminalsKey
        let previousShowValue = defaults.object(forKey: showKey)
        let previousFocusValue = defaults.object(forKey: focusKey)
        defer {
            if let previousShowValue {
                defaults.set(previousShowValue, forKey: showKey)
            } else {
                defaults.removeObject(forKey: showKey)
            }
            if let previousFocusValue {
                defaults.set(previousFocusValue, forKey: focusKey)
            } else {
                defaults.removeObject(forKey: focusKey)
            }
        }

        defaults.set(false, forKey: showKey)
        defaults.set(false, forKey: focusKey)

        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let initialPanel = workspace.focusedTerminalPanel,
              let paneId = workspace.bonsplitController.focusedPaneId,
              let newTabPanel = workspace.newTerminalSurface(inPane: paneId, focus: true) else {
            XCTFail("Expected initial and new terminal panels")
            return
        }

        XCTAssertFalse(initialPanel.isTextBoxActive)
        XCTAssertFalse(newTabPanel.isTextBoxActive)
    }

    func testNewSurfaceFocusesCreatedSurface() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace else {
            XCTFail("Expected a selected workspace")
            return
        }

        let beforePanels = Set(workspace.panels.keys)
        manager.newSurface()
        let afterPanels = Set(workspace.panels.keys)

        let createdPanels = afterPanels.subtracting(beforePanels)
        XCTAssertEqual(createdPanels.count, 1, "Expected one new surface for Cmd+T path")
        guard let createdPanelId = createdPanels.first else { return }

        XCTAssertEqual(
            workspace.focusedPanelId,
            createdPanelId,
            "Expected newly created surface to be focused"
        )
    }

    func testOpenBrowserInsertAtEndPlacesNewBrowserAtPaneEnd() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId else {
            XCTFail("Expected focused workspace and pane")
            return
        }

        // Add one extra surface so we verify append-to-end rather than first insert behavior.
        _ = workspace.newTerminalSurface(inPane: paneId, focus: false)

        guard let browserPanelId = manager.openBrowser(insertAtEnd: true) else {
            XCTFail("Expected browser panel to be created")
            return
        }

        let tabs = workspace.bonsplitController.tabs(inPane: paneId)
        guard let lastSurfaceId = tabs.last?.id else {
            XCTFail("Expected at least one surface in pane")
            return
        }

        XCTAssertEqual(
            workspace.panelIdFromSurfaceId(lastSurfaceId),
            browserPanelId,
            "Expected Cmd+Shift+B/Cmd+L open path to append browser surface at end"
        )
        XCTAssertEqual(workspace.focusedPanelId, browserPanelId, "Expected opened browser surface to be focused")
    }

    func testToggleOmnibarFocusedBrowserIsSurfaceSpecific() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let browserPanelId = manager.openBrowser(),
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            XCTFail("Expected focused browser panel")
            return
        }

        XCTAssertTrue(browserPanel.isOmnibarVisible)
        XCTAssertTrue(manager.toggleOmnibarFocusedBrowser())
        XCTAssertFalse(browserPanel.isOmnibarVisible)

        let otherBrowser = workspace.newBrowserSurface(
            inPane: workspace.paneId(forPanelId: browserPanelId) ?? workspace.bonsplitController.allPaneIds[0],
            focus: true
        )
        XCTAssertTrue(otherBrowser?.isOmnibarVisible ?? false)
    }

    func testNewBrowserSurfaceCanSelectBackgroundPaneWithoutTakingFocus() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let sourcePanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: sourcePanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightPanel.id),
              let url = URL(string: "file:///tmp/cmux-diff.html") else {
            XCTFail("Expected split setup to succeed")
            return
        }
        workspace.focusPanel(sourcePanelId)
        let sourcePaneBefore = workspace.bonsplitController.focusedPaneId

        guard let browserPanel = workspace.newBrowserSurface(
            inPane: rightPaneId,
            url: url,
            focus: false,
            selectWhenNotFocused: true,
            omnibarVisible: false
        ), let browserSurfaceId = workspace.surfaceIdFromPanelId(browserPanel.id) else {
            XCTFail("Expected background browser surface to be created")
            return
        }

        XCTAssertEqual(workspace.focusedPanelId, sourcePanelId)
        XCTAssertEqual(workspace.bonsplitController.focusedPaneId, sourcePaneBefore)
        XCTAssertEqual(workspace.bonsplitController.selectedTab(inPane: rightPaneId)?.id, browserSurfaceId)
        XCTAssertFalse(browserPanel.isOmnibarVisible)
    }

    func testDuplicateBrowserPreservesDiffViewerChromeAndProxyBypass() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/token/diff.html#cmux-diff-viewer"))
        let browserPanel = try XCTUnwrap(
            workspace.newBrowserSurface(
                inPane: paneId,
                url: url,
                focus: true,
                omnibarVisible: false,
                bypassRemoteProxy: true
            )
        )
        guard browserPanel.setMuted(true) else {
            throw XCTSkip("WKWebView page-audio mute selector is unavailable")
        }

        let duplicate = try XCTUnwrap(workspace.duplicateBrowserToRight(panelId: browserPanel.id, focus: false))
        let duplicateTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(duplicate.id))
        let duplicateTab = try XCTUnwrap(workspace.bonsplitController.tab(duplicateTabId))

        XCTAssertFalse(duplicate.isOmnibarVisible)
        XCTAssertTrue(duplicate.bypassesRemoteWorkspaceProxyForTabDuplication)
        XCTAssertTrue(duplicate.isMuted)
        XCTAssertTrue(duplicateTab.isAudioMuted)
    }

    func testBrowserAudioMuteContextActionTogglesPanelAndTabState() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let browserPanel = try XCTUnwrap(workspace.newBrowserSurface(inPane: paneId, focus: true))
        let tabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(browserPanel.id))
        guard browserPanel.setMuted(false) else {
            throw XCTSkip("WKWebView page-audio mute selector is unavailable")
        }

        let initialTab = try XCTUnwrap(workspace.bonsplitController.tab(tabId))
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .toggleAudioMute,
            for: initialTab,
            inPane: paneId
        )

        XCTAssertTrue(browserPanel.isMuted)
        XCTAssertTrue(try XCTUnwrap(workspace.bonsplitController.tab(tabId)).isAudioMuted)

        let mutedTab = try XCTUnwrap(workspace.bonsplitController.tab(tabId))
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .toggleAudioMute,
            for: mutedTab,
            inPane: paneId
        )

        XCTAssertFalse(browserPanel.isMuted)
        XCTAssertFalse(try XCTUnwrap(workspace.bonsplitController.tab(tabId)).isAudioMuted)
    }

    func testOpenBrowserInWorkspaceSplitRightSelectsTargetWorkspaceAndCreatesSplit() {
        let manager = TabManager()
        guard let initialWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected initial selected workspace")
            return
        }
        guard let url = URL(string: "https://example.com/pull/123") else {
            XCTFail("Expected test URL to be valid")
            return
        }

        let targetWorkspace = manager.addWorkspace(select: false)
        manager.selectWorkspace(initialWorkspace)
        let initialPaneCount = targetWorkspace.bonsplitController.allPaneIds.count
        let initialPanelCount = targetWorkspace.panels.count

        guard let browserPanelId = manager.openBrowser(
            inWorkspace: targetWorkspace.id,
            url: url,
            preferSplitRight: true,
            insertAtEnd: true
        ) else {
            XCTFail("Expected browser panel to be created in target workspace")
            return
        }

        XCTAssertEqual(manager.selectedTabId, targetWorkspace.id, "Expected target workspace to become selected")
        XCTAssertEqual(
            targetWorkspace.bonsplitController.allPaneIds.count,
            initialPaneCount + 1,
            "Expected split-right browser open to create a new pane"
        )
        XCTAssertEqual(
            targetWorkspace.panels.count,
            initialPanelCount + 1,
            "Expected browser panel count to increase by one"
        )
        XCTAssertEqual(
            targetWorkspace.focusedPanelId,
            browserPanelId,
            "Expected created browser panel to be focused in target workspace"
        )
        XCTAssertTrue(
            targetWorkspace.panels[browserPanelId] is BrowserPanel,
            "Expected created panel to be a browser panel"
        )
    }

    func testOpenBrowserInWorkspaceSplitRightReusesTopRightPaneWhenAlreadySplit() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let topRightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal),
              workspace.newTerminalSplit(from: topRightPanel.id, orientation: .vertical) != nil,
              let topRightPaneId = workspace.paneId(forPanelId: topRightPanel.id),
              let url = URL(string: "https://example.com/pull/456") else {
            XCTFail("Expected split setup to succeed")
            return
        }

        let initialPaneCount = workspace.bonsplitController.allPaneIds.count

        guard let browserPanelId = manager.openBrowser(
            inWorkspace: workspace.id,
            url: url,
            preferSplitRight: true,
            insertAtEnd: true
        ) else {
            XCTFail("Expected browser panel to be created")
            return
        }

        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            initialPaneCount,
            "Expected split-right browser open to reuse existing panes"
        )
        XCTAssertEqual(
            workspace.paneId(forPanelId: browserPanelId),
            topRightPaneId,
            "Expected browser to open in the top-right pane when multiple splits already exist"
        )

        let targetPaneTabs = workspace.bonsplitController.tabs(inPane: topRightPaneId)
        guard let lastSurfaceId = targetPaneTabs.last?.id else {
            XCTFail("Expected top-right pane to contain tabs")
            return
        }
        XCTAssertEqual(
            workspace.panelIdFromSurfaceId(lastSurfaceId),
            browserPanelId,
            "Expected browser surface to be appended at end in the reused top-right pane"
        )
    }
}


