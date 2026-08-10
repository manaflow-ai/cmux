import AppKit
import Bonsplit
import Combine
import CmuxSimulatorUI
import CmuxSettings
import CmuxTerminal
import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
private typealias AppStoredShortcut = cmux_DEV.StoredShortcut
#elseif canImport(cmux)
@testable import cmux
private typealias AppStoredShortcut = cmux.StoredShortcut
#endif

@Suite("Dock shortcut routing", .serialized)
struct DockShortcutRoutingTests {
    @Test("Customized next-surface shortcut targets the focused Dock")
    @MainActor
    func customizedNextSurfaceTargetsFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let firstPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                let secondPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                harness.dock.focusPanel(firstPanel)
                let mainPanelBefore = harness.mainWorkspace.focusedPanelId

                let customShortcut = AppStoredShortcut(
                    key: "y",
                    command: true,
                    shift: false,
                    option: true,
                    control: true
                )
                KeyboardShortcutSettings.setShortcut(customShortcut, for: .nextSurface)

                #expect(Self.dispatch(customShortcut, in: harness))
                #expect(harness.dock.focusedPanelId == secondPanel)
                #expect(harness.mainWorkspace.focusedPanelId == mainPanelBefore)
            }
        }
    }

    @Test("Customized directional-focus shortcut targets the focused Dock")
    @MainActor
    func customizedDirectionalFocusTargetsFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let leftPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                let rightPanel = try #require(
                    harness.dock.newSplit(
                        kind: .terminal,
                        orientation: .horizontal,
                        insertFirst: false,
                        sourcePanelId: leftPanel,
                        focus: true
                    )
                )
                let rightPane = try #require(harness.dock.paneId(forPanelId: rightPanel))
                harness.dock.focusPanel(leftPanel)
                let mainPanelBefore = harness.mainWorkspace.focusedPanelId

                let customShortcut = AppStoredShortcut(
                    key: "y",
                    command: true,
                    shift: false,
                    option: true,
                    control: true
                )
                KeyboardShortcutSettings.setShortcut(customShortcut, for: .focusRight)

                #expect(Self.dispatch(customShortcut, in: harness))
                #expect(harness.dock.bonsplitController.focusedPaneId == rightPane)
                #expect(harness.mainWorkspace.focusedPanelId == mainPanelBefore)
            }
        }
    }

    @Test("Legacy tab shortcuts target the focused Dock")
    @MainActor
    func legacyTabShortcutsTargetFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let firstPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                let secondPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                harness.dock.focusPanel(firstPanel)
                let mainPanelBefore = harness.mainWorkspace.focusedPanelId
                KeyboardShortcutSettings.setShortcut(.unbound, for: .nextSurface)
                KeyboardShortcutSettings.setShortcut(.unbound, for: .prevSurface)

                let next = AppStoredShortcut(
                    key: "\t",
                    command: false,
                    shift: false,
                    option: false,
                    control: true
                )
                #expect(Self.dispatch(next, in: harness))
                #expect(harness.dock.focusedPanelId == secondPanel)

                let previous = AppStoredShortcut(
                    key: "\t",
                    command: false,
                    shift: true,
                    option: false,
                    control: true
                )
                #expect(Self.dispatch(previous, in: harness))
                #expect(harness.dock.focusedPanelId == firstPanel)
                #expect(harness.mainWorkspace.focusedPanelId == mainPanelBefore)
            }
        }
    }

    @Test("Configured actions keep precedence over legacy Dock tab shortcuts")
    @MainActor
    func configuredActionPrecedesLegacyDockTabShortcut() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let firstPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                _ = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                harness.dock.focusPanel(firstPanel)

                let controlTab = AppStoredShortcut(
                    key: "\t",
                    command: false,
                    shift: false,
                    option: false,
                    control: true
                )
                KeyboardShortcutSettings.setShortcut(controlTab, for: .toggleTerminalCopyMode)

                _ = Self.dispatch(controlTab, in: harness)
                #expect(harness.dock.focusedPanelId == firstPanel)
            }
        }
    }

    @Test("Ghostty split-navigation shortcuts target the focused Dock")
    @MainActor
    func ghosttySplitNavigationTargetsFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let leftPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                let rightPanel = try #require(
                    harness.dock.newSplit(
                        kind: .terminal,
                        orientation: .horizontal,
                        insertFirst: false,
                        sourcePanelId: leftPanel,
                        focus: true
                    )
                )
                let rightPane = try #require(harness.dock.paneId(forPanelId: rightPanel))
                harness.dock.focusPanel(leftPanel)
                let mainPanelBefore = harness.mainWorkspace.focusedPanelId
                KeyboardShortcutSettings.setShortcut(.unbound, for: .focusRight)
                let originalGhosttyShortcut = harness.appDelegate.ghosttyGotoSplitRightShortcut
                defer { harness.appDelegate.ghosttyGotoSplitRightShortcut = originalGhosttyShortcut }
                harness.appDelegate.ghosttyGotoSplitRightShortcut = Self.customShortcut(key: "y")
                let ghosttyShortcut = try #require(
                    harness.appDelegate.ghosttyGotoSplitShortcut(for: .right)
                )

                #expect(Self.dispatch(ghosttyShortcut, in: harness))
                #expect(harness.dock.bonsplitController.focusedPaneId == rightPane)
                #expect(harness.mainWorkspace.focusedPanelId == mainPanelBefore)
            }
        }
    }

    @Test("Focus-history shortcuts navigate focused Dock surfaces")
    @MainActor
    func focusHistoryNavigatesFocusedDockSurfaces() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let firstPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                let secondPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                harness.dock.focusPanel(firstPanel)
                harness.dock.focusPanel(secondPanel)

                let back = KeyboardShortcutSettings.Action.focusHistoryBack.defaultShortcut
                let forward = KeyboardShortcutSettings.Action.focusHistoryForward.defaultShortcut
                KeyboardShortcutSettings.setShortcut(back, for: .focusHistoryBack)
                KeyboardShortcutSettings.setShortcut(forward, for: .focusHistoryForward)

                #expect(Self.dispatch(back, in: harness))
                #expect(harness.dock.focusedPanelId == firstPanel)
                #expect(Self.dispatch(forward, in: harness))
                #expect(harness.dock.focusedPanelId == secondPanel)
            }
        }
    }

    @Test("Customized previous and numbered-surface shortcuts target the focused Dock")
    @MainActor
    func customizedPreviousAndNumberedSurfaceTargetFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let firstPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                let secondPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                let thirdPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                harness.dock.focusPanel(secondPanel)
                let mainPanelBefore = harness.mainWorkspace.focusedPanelId

                let previousShortcut = Self.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(previousShortcut, for: .prevSurface)
                #expect(Self.dispatch(previousShortcut, in: harness))
                #expect(harness.dock.focusedPanelId == firstPanel)

                let numberedShortcut = AppStoredShortcut(
                    key: "3",
                    command: false,
                    shift: false,
                    option: true,
                    control: true
                )
                KeyboardShortcutSettings.setShortcut(numberedShortcut, for: .selectSurfaceByNumber)
                #expect(Self.dispatch(numberedShortcut, in: harness))
                #expect(harness.dock.focusedPanelId == thirdPanel)
                #expect(harness.mainWorkspace.focusedPanelId == mainPanelBefore)
            }
        }
    }

    @Test("Customized move-surface shortcuts reorder only focused Dock surfaces")
    @MainActor
    func customizedMoveSurfaceReordersFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let firstPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                let secondPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                let firstTab = try #require(harness.dock.surfaceId(forPanelId: firstPanel))
                let secondTab = try #require(harness.dock.surfaceId(forPanelId: secondPanel))
                harness.dock.focusPanel(secondPanel)
                let mainPanelBefore = harness.mainWorkspace.focusedPanelId

                let moveLeft = Self.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(moveLeft, for: .moveSurfaceLeft)
                #expect(Self.dispatch(moveLeft, in: harness))
                #expect(harness.dock.bonsplitController.tabs(inPane: harness.rootPane).map(\.id) == [secondTab, firstTab])

                let moveRight = Self.customShortcut(key: "u")
                KeyboardShortcutSettings.setShortcut(moveRight, for: .moveSurfaceRight)
                #expect(Self.dispatch(moveRight, in: harness))
                #expect(harness.dock.bonsplitController.tabs(inPane: harness.rootPane).map(\.id) == [firstTab, secondTab])
                #expect(harness.mainWorkspace.focusedPanelId == mainPanelBefore)
            }
        }
    }

    @Test("Customized zoom and flash shortcuts target the focused Dock")
    @MainActor
    func customizedZoomAndFlashTargetFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let panel = try harness.dock.seedShortcutTestPanel(inPane: harness.rootPane)
                _ = try #require(
                    harness.dock.newSplit(
                        kind: .terminal,
                        orientation: .horizontal,
                        insertFirst: false,
                        sourcePanelId: panel.id,
                        focus: true
                    )
                )
                harness.dock.focusPanel(panel.id)
                let mainPanelBefore = harness.mainWorkspace.focusedPanelId

                let zoom = Self.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(zoom, for: .toggleSplitZoom)
                #expect(!harness.dock.bonsplitController.isSplitZoomed)
                #expect(Self.dispatch(zoom, in: harness))
                #expect(harness.dock.bonsplitController.isSplitZoomed)

                let flash = Self.customShortcut(key: "u")
                KeyboardShortcutSettings.setShortcut(flash, for: .triggerFlash)
                #expect(Self.dispatch(flash, in: harness))
                #expect(panel.flashReasons == [.userInitiated])
                #expect(harness.mainWorkspace.focusedPanelId == mainPanelBefore)
            }
        }
    }

    @Test("Focus address bar targets the focused Dock browser")
    @MainActor
    func focusAddressBarTargetsFocusedDockBrowser() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let dockBrowserId = try #require(
                    harness.dock.newSurface(
                        kind: .browser,
                        inPane: harness.rootPane,
                        focus: true
                    )
                )
                let mainPanelIdsBefore = Set(harness.mainWorkspace.panels.keys)
                let shortcut = KeyboardShortcutSettings.Action
                    .focusBrowserAddressBar.defaultShortcut
                KeyboardShortcutSettings.setShortcut(
                    shortcut,
                    for: .focusBrowserAddressBar
                )

                #expect(Self.dispatch(shortcut, in: harness))
                #expect(
                    harness.appDelegate.focusedBrowserAddressBarPanelId() ==
                        dockBrowserId
                )
                #expect(Set(harness.mainWorkspace.panels.keys) == mainPanelIdsBefore)
            }
        }
    }

    @Test("Focus address bar preserves main fallback without a focused Dock browser")
    @MainActor
    func focusAddressBarFallsBackWithoutFocusedDockBrowser() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let mainPane = try #require(
                    harness.mainWorkspace.bonsplitController.focusedPaneId
                )
                let mainBrowser = try #require(
                    harness.mainWorkspace.newBrowserSurface(
                        inPane: mainPane,
                        focus: true
                    )
                )
                let dockTerminalId = try #require(
                    harness.dock.newSurface(
                        kind: .terminal,
                        inPane: harness.rootPane,
                        focus: true
                    )
                )
                let shortcut = KeyboardShortcutSettings.Action
                    .focusBrowserAddressBar.defaultShortcut
                KeyboardShortcutSettings.setShortcut(
                    shortcut,
                    for: .focusBrowserAddressBar
                )

                #expect(Self.dispatch(shortcut, in: harness))
                #expect(
                    harness.appDelegate.focusedBrowserAddressBarPanelId() ==
                        mainBrowser.id
                )
                #expect(harness.dock.focusedPanelId == dockTerminalId)
            }
        }
    }

    @Test("Reopen closed panel restores Dock history without consuming main history")
    @MainActor
    func reopenClosedPanelUsesFocusedDockHistory() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                ClosedItemHistoryStore.shared.removeAll()
                defer { ClosedItemHistoryStore.shared.removeAll() }

                let mainPane = try #require(
                    harness.mainWorkspace.bonsplitController.focusedPaneId
                )
                let mainBrowser = try #require(
                    harness.mainWorkspace.newBrowserSurface(
                        inPane: mainPane,
                        url: URL(string: "https://example.com"),
                        focus: true
                    )
                )
                harness.mainWorkspace.markCloseHistoryEligible(
                    panelId: mainBrowser.id
                )
                #expect(
                    harness.mainWorkspace.closePanel(
                        mainBrowser.id,
                        force: true
                    )
                )
                #expect(ClosedItemHistoryStore.shared.canReopen)

                let dockTerminalId = try #require(
                    harness.dock.newSurface(
                        kind: .terminal,
                        inPane: harness.rootPane,
                        focus: true
                    )
                )
                let restoredURL = try #require(
                    URL(string: "https://example.org/")
                )
                let dockBrowserId = try #require(
                    harness.dock.newSurface(
                        kind: .browser,
                        inPane: harness.rootPane,
                        url: restoredURL,
                        focus: true
                    )
                )
                #expect(harness.dock.closePanel(dockBrowserId))
                harness.dock.focusPanel(dockTerminalId)

                let shortcut = KeyboardShortcutSettings.Action
                    .reopenClosedBrowserPanel.defaultShortcut
                KeyboardShortcutSettings.setShortcut(
                    shortcut,
                    for: .reopenClosedBrowserPanel
                )

                #expect(Self.dispatch(shortcut, in: harness))
                let restoredBrowser = try #require(
                    harness.dock.panels.values.compactMap {
                        $0 as? BrowserPanel
                    }.first
                )
                #expect(restoredBrowser.currentURL == restoredURL)
                #expect(
                    !harness.mainWorkspace.panels.values.contains {
                        $0 is BrowserPanel
                    }
                )
                #expect(ClosedItemHistoryStore.shared.canReopen)
            }
        }
    }

    @Test("Previous and next pane shortcuts cycle focused Dock panes")
    @MainActor
    func paneCyclingTargetsFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let leftPanel = try #require(
                    harness.dock.newSurface(
                        kind: .terminal,
                        inPane: harness.rootPane,
                        focus: true
                    )
                )
                let rightPanel = try #require(
                    harness.dock.newSplit(
                        kind: .terminal,
                        orientation: .horizontal,
                        insertFirst: false,
                        sourcePanelId: leftPanel,
                        focus: true
                    )
                )
                let rightPane = try #require(
                    harness.dock.paneId(forPanelId: rightPanel)
                )
                harness.dock.focusPanel(leftPanel)
                let mainPanelBefore = harness.mainWorkspace.focusedPanelId

                let previous = Self.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(
                    previous,
                    for: .focusPreviousPane
                )
                #expect(Self.dispatch(previous, in: harness))
                #expect(
                    harness.dock.bonsplitController.focusedPaneId == rightPane
                )

                let next = Self.customShortcut(key: "u")
                KeyboardShortcutSettings.setShortcut(next, for: .focusNextPane)
                #expect(Self.dispatch(next, in: harness))
                #expect(
                    harness.dock.bonsplitController.focusedPaneId ==
                        harness.rootPane
                )
                #expect(harness.mainWorkspace.focusedPanelId == mainPanelBefore)
            }
        }
    }

    @Test("Equalize splits targets the focused Dock")
    @MainActor
    func equalizeSplitsTargetsFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let firstPanel = try #require(
                    harness.dock.newSurface(
                        kind: .terminal,
                        inPane: harness.rootPane,
                        focus: true
                    )
                )
                _ = try #require(
                    harness.dock.newSplit(
                        kind: .terminal,
                        orientation: .horizontal,
                        insertFirst: false,
                        sourcePanelId: firstPanel,
                        focus: true
                    )
                )
                let split = try #require(
                    Self.splitNodes(
                        in: harness.dock.bonsplitController.treeSnapshot()
                    ).first
                )
                let splitId = try #require(UUID(uuidString: split.id))
                #expect(
                    harness.dock.bonsplitController.setDividerPosition(
                        0.2,
                        forSplit: splitId
                    )
                )

                let shortcut = Self.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(
                    shortcut,
                    for: .equalizeSplits
                )
                #expect(Self.dispatch(shortcut, in: harness))

                let updatedSplit = try #require(
                    Self.splitNodes(
                        in: harness.dock.bonsplitController.treeSnapshot()
                    ).first { $0.id == split.id }
                )
                #expect(abs(updatedSplit.dividerPosition - 0.5) < 0.000_1)
            }
        }
    }

    @Test("Close other tabs targets the focused Dock pane")
    @MainActor
    func closeOtherTabsTargetsFocusedDockPane() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let warningStore = CloseTabWarningStore(
                    defaults: harness.tabManager.closeTabWarningDefaults
                )
                let previousWarning = warningStore.warnsBeforeClosingTab
                warningStore.setWarnsBeforeClosingTab(false)
                defer {
                    warningStore.setWarnsBeforeClosingTab(previousWarning)
                }

                _ = try #require(
                    harness.dock.newSurface(
                        kind: .terminal,
                        inPane: harness.rootPane,
                        focus: true
                    )
                )
                let retainedPanel = try #require(
                    harness.dock.newSurface(
                        kind: .terminal,
                        inPane: harness.rootPane,
                        focus: true
                    )
                )
                _ = try #require(
                    harness.dock.newSurface(
                        kind: .terminal,
                        inPane: harness.rootPane,
                        focus: true
                    )
                )
                harness.dock.focusPanel(retainedPanel)
                let mainPanelIdsBefore = Set(harness.mainWorkspace.panels.keys)

                let shortcut = Self.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(
                    shortcut,
                    for: .closeOtherTabsInPane
                )
                #expect(Self.dispatch(shortcut, in: harness))
                #expect(Set(harness.dock.panels.keys) == [retainedPanel])
                #expect(Set(harness.mainWorkspace.panels.keys) == mainPanelIdsBefore)
            }
        }
    }

    @Test("Terminal and find shortcuts target the focused Dock terminal")
    @MainActor
    func terminalAndFindShortcutsTargetFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let dockTerminalId = try #require(
                    harness.dock.newSurface(
                        kind: .terminal,
                        inPane: harness.rootPane,
                        focus: true
                    )
                )
                let dockTerminal = try #require(
                    harness.dock.panels[dockTerminalId] as? TerminalPanel
                )
                let mainTerminal = try #require(
                    harness.mainWorkspace.focusedTerminalInputTarget()?.panel
                )
                dockTerminal.surface.requestInputDemandSurfaceStartIfNeeded()
                await Self.waitForLiveSurface(dockTerminal.surface)
                try #require(dockTerminal.surface.hasLiveSurface)

                let copyMode = Self.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(
                    copyMode,
                    for: .toggleTerminalCopyMode
                )
                #expect(Self.dispatch(copyMode, in: harness))
                #expect(
                    dockTerminal.hostedView.surfaceView
                        .isKeyboardCopyModeActive
                )
                #expect(
                    !mainTerminal.hostedView.surfaceView
                        .isKeyboardCopyModeActive
                )

                let textBox = Self.customShortcut(key: "u")
                KeyboardShortcutSettings.setShortcut(
                    textBox,
                    for: .focusTextBoxInput
                )
                #expect(Self.dispatch(textBox, in: harness))
                #expect(dockTerminal.isTextBoxActive)
                #expect(!mainTerminal.isTextBoxActive)

                let find = Self.customShortcut(key: "o")
                KeyboardShortcutSettings.setShortcut(find, for: .find)
                let searchFocusNotifications =
                    NotificationCenter.default.notifications(
                        named: .ghosttySearchFocus,
                        object: dockTerminal.surface
                    )
                try #require(Self.dispatch(find, in: harness))
                for await _ in searchFocusNotifications { break }
                #expect(dockTerminal.searchState != nil)
                #expect(mainTerminal.searchState == nil)

                mainTerminal.searchState = nil
                dockTerminal.searchState = TerminalSurface.SearchState(
                    needle: "dock"
                )
                let hideFind = Self.customShortcut(key: "p")
                KeyboardShortcutSettings.setShortcut(
                    hideFind,
                    for: .hideFind
                )
                #expect(Self.dispatch(hideFind, in: harness))
                #expect(dockTerminal.searchState == nil)
                #expect(mainTerminal.searchState == nil)
            }
        }
    }

    @Test("React Grab shortcut does not target the background workspace")
    @MainActor
    func reactGrabDoesNotTargetBackgroundWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let mainTerminalId = try #require(
                    harness.mainWorkspace.focusedPanelId
                )
                let mainPane = try #require(
                    harness.mainWorkspace.paneId(
                        forPanelId: mainTerminalId
                    )
                )
                let mainBrowser = try #require(
                    harness.mainWorkspace.newBrowserSurface(
                        inPane: mainPane,
                        focus: false
                    )
                )
                harness.mainWorkspace.focusPanel(mainTerminalId)

                let dockBrowserId = try #require(
                    harness.dock.newSurface(
                        kind: .browser,
                        inPane: harness.rootPane,
                        focus: false
                    )
                )
                let dockBrowser = try #require(
                    harness.dock.browserPanel(for: dockBrowserId)
                )
                let dockTerminalId = try #require(
                    harness.dock.newSurface(
                        kind: .terminal,
                        inPane: harness.rootPane,
                        focus: true
                    )
                )
                let shortcut = Self.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(
                    shortcut,
                    for: .toggleReactGrab
                )

                #expect(Self.dispatch(shortcut, in: harness))
                #expect(
                    harness.mainWorkspace.focusedPanelId == mainTerminalId
                )
                #expect(
                    harness.mainWorkspace.focusedPanelId != mainBrowser.id
                )
                #expect(harness.dock.focusedPanelId == dockBrowserId)
                #expect(
                    dockBrowser.pendingReactGrabReturnTargetPanelId ==
                        dockTerminalId
                )
            }
        }
    }

    @Test("Move-to-pane shortcut moves the focused Dock surface")
    @MainActor
    func moveToPaneTargetsFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let movedPanelId = try #require(
                    harness.mainWorkspace.focusedPanelId
                )
                let sourcePaneId = try #require(
                    harness.mainWorkspace.paneId(forPanelId: movedPanelId)
                )
                _ = try #require(
                    harness.mainWorkspace.newTerminalSplit(
                        from: movedPanelId,
                        orientation: .horizontal,
                        focus: false
                    )
                )
                harness.mainWorkspace.focusPanel(movedPanelId)

                let dockPanelToMove = try #require(
                    harness.dock.newSurface(
                        kind: .terminal,
                        inPane: harness.rootPane,
                        focus: true
                    )
                )
                _ = try #require(
                    harness.dock.newSurface(
                        kind: .terminal,
                        inPane: harness.rootPane,
                        focus: false
                    )
                )
                let destinationPanel = try #require(
                    harness.dock.newSplit(
                        kind: .terminal,
                        orientation: .horizontal,
                        insertFirst: false,
                        sourcePanelId: dockPanelToMove,
                        focus: false
                    )
                )
                let destinationPane = try #require(
                    harness.dock.paneId(forPanelId: destinationPanel)
                )
                harness.dock.focusPanel(dockPanelToMove)
                let shortcut = Self.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(
                    shortcut,
                    for: .moveSurfaceToPaneRight
                )

                #expect(Self.dispatch(shortcut, in: harness))
                #expect(
                    harness.mainWorkspace.paneId(forPanelId: movedPanelId) ==
                        sourcePaneId
                )
                #expect(harness.mainWorkspace.focusedPanelId == movedPanelId)
                #expect(
                    harness.dock.paneId(forPanelId: dockPanelToMove) ==
                        destinationPane
                )
                #expect(harness.dock.focusedPanelId == dockPanelToMove)
            }
        }
    }

    @Test("Repeated move-to-pane shortcut does not create a missing pane")
    @MainActor
    func repeatedMoveToPaneDoesNotCreateMissingPane() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let movedPanelId = try #require(harness.mainWorkspace.focusedPanelId)
                let paneIdsBefore = harness.mainWorkspace.bonsplitController.allPaneIds
                let panelIdsBefore = Set(harness.mainWorkspace.panels.keys)
                let shortcut = Self.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(
                    shortcut,
                    for: .moveSurfaceToPaneRight
                )
                harness.appDelegate.noteMainPanelKeyboardFocusIntent(
                    workspaceId: harness.mainWorkspace.id,
                    panelId: movedPanelId,
                    in: harness.window
                )

                #expect(Self.dispatch(shortcut, in: harness, isARepeat: true))
                #expect(harness.mainWorkspace.bonsplitController.allPaneIds == paneIdsBefore)
                #expect(Set(harness.mainWorkspace.panels.keys) == panelIdsBefore)
                #expect(harness.mainWorkspace.focusedPanelId == movedPanelId)
            }
        }
    }

    @Test("Repeated move-to-pane shortcut still uses an existing destination")
    @MainActor
    func repeatedMoveToPaneUsesExistingDestination() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let movedPanelId = try #require(harness.mainWorkspace.focusedPanelId)
                let sourcePaneId = try #require(
                    harness.mainWorkspace.paneId(forPanelId: movedPanelId)
                )
                _ = try #require(
                    harness.mainWorkspace.newTerminalSurface(
                        inPane: sourcePaneId,
                        focus: false
                    )
                )
                let destinationPanel = try #require(
                    harness.mainWorkspace.newTerminalSplit(
                        from: movedPanelId,
                        orientation: .horizontal,
                        focus: false
                    )
                )
                let destinationPaneId = try #require(
                    harness.mainWorkspace.paneId(forPanelId: destinationPanel.id)
                )
                harness.mainWorkspace.focusPanel(movedPanelId)
                let shortcut = Self.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(
                    shortcut,
                    for: .moveSurfaceToPaneRight
                )
                harness.appDelegate.noteMainPanelKeyboardFocusIntent(
                    workspaceId: harness.mainWorkspace.id,
                    panelId: movedPanelId,
                    in: harness.window
                )

                #expect(Self.dispatch(shortcut, in: harness, isARepeat: true))
                #expect(
                    harness.mainWorkspace.paneId(forPanelId: movedPanelId) ==
                        destinationPaneId
                )
            }
        }
    }

    @Test("Simulator shortcuts target the focused Dock Simulator")
    @MainActor
    func simulatorShortcutTargetsFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let flags = CmuxFeatureFlags.shared
                let simulatorFlag = CmuxFeatureFlags.allFlags[5]
                let previousOverride = flags.overrideValue(for: simulatorFlag)
                flags.setOverride(true, for: simulatorFlag)
                defer { flags.setOverride(previousOverride, for: simulatorFlag) }

                let panel = try harness.dock.seedSimulatorPanel(inPane: harness.rootPane)
                defer { panel.close() }
                let responder = DockSimulatorResponder(
                    owner: ObjectIdentifier(panel.coordinator)
                )
                harness.window.contentView = responder
                #expect(harness.window.makeFirstResponder(responder))
                let shortcut = Self.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(shortcut, for: .simulatorHome)

                #expect(Self.dispatch(shortcut, in: harness))
            }
        }
    }

    @Test("Simulator tool editors retain panel focus without routing Simulator shortcuts")
    @MainActor
    func simulatorToolEditorRetainsPanelFocus() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let flags = CmuxFeatureFlags.shared
                let simulatorFlag = CmuxFeatureFlags.allFlags[5]
                let previousOverride = flags.overrideValue(for: simulatorFlag)
                flags.setOverride(true, for: simulatorFlag)
                defer { flags.setOverride(previousOverride, for: simulatorFlag) }

                let panel = try harness.dock.seedSimulatorPanel(inPane: harness.rootPane)
                defer { panel.close() }
                let ownershipView = NSView(frame: harness.window.contentView?.bounds ?? .zero)
                let textField = NSTextField(
                    frame: NSRect(x: 20, y: 20, width: 240, height: 24)
                )
                ownershipView.addSubview(textField)
                harness.window.contentView = ownershipView
                panel.setFocusOwnershipView(ownershipView)
                defer { panel.clearFocusOwnershipView(ownershipView) }
                #expect(harness.window.makeFirstResponder(textField))
                let firstResponder = try #require(harness.window.firstResponder)
                #expect(shortcutResponderAcceptsTextEditing(firstResponder))

                let shortcut = Self.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(shortcut, for: .simulatorHome)
                let event = try #require(Self.event(shortcut, in: harness))
                let focus = harness.appDelegate.shortcutEventFocusContext(event)
                var canvasContext = focus.shortcutContext
                canvasContext.setBool(
                    ShortcutContextKnownKey.workspaceCanvasLayout.rawValue,
                    true
                )

                #expect(focus.simulatorFocused)
                #expect(focus.shortcutContext.bool(
                    ShortcutContextKnownKey.simulatorFocus.rawValue
                ))
                #expect(!focus.shortcutContext.bool(
                    ShortcutContextKnownKey.terminalFocus.rawValue
                ))
                #expect(!KeyboardShortcutSettings.effectiveWhenClause(
                    for: .canvasZoomReset
                ).evaluate(canvasContext))
                #expect(!harness.appDelegate.debugHandleCustomShortcut(event: event))
            }
        }
    }
}

private extension DockShortcutRoutingTests {
    @MainActor
    struct Harness {
        let appDelegate: AppDelegate
        let dock: DockSplitStore
        let mainWorkspace: Workspace
        let tabManager: TabManager
        let rootPane: PaneID
        let window: NSWindow
    }

    @MainActor
    static func withHarness(
        _ body: (Harness) async throws -> Void
    ) async throws {
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-dock-shortcut-routing"
        )
        KeyboardShortcutSettings.resetAll()

        let appDelegate = AppDelegate()
        let suiteName = "DockShortcutRoutingTests.paneHistory.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(true, for: SettingCatalog().app.focusHistoryIncludesPanesAndTabs)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            settings: settings,
            closeTabWarningDefaults: defaults
        )
        let fileExplorerState = FileExplorerState()
        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")

        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        TerminalController.shared.setActiveTabManager(manager)
        appDelegate.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: fileExplorerState
        )
        window.makeKeyAndOrderFront(nil)

        let mainWorkspace = try #require(manager.tabs.first)
        let dock = appDelegate.windowDock(forWindowId: windowId)
        let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
        dock.setVisibleInUI(true)
        fileExplorerState.setVisible(true)
        fileExplorerState.mode = .dock
        appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: window)

        defer {
            defaults.removePersistentDomain(forName: suiteName)
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            TerminalController.shared.setActiveTabManager(previousManager)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            window.orderOut(nil)
            window.close()
            AppDelegate.shared = previousAppDelegate
        }

        try await body(Harness(
            appDelegate: appDelegate,
            dock: dock,
            mainWorkspace: mainWorkspace,
            tabManager: manager,
            rootPane: rootPane,
            window: window
        ))
    }

    @MainActor
    static func waitForLiveSurface(_ surface: TerminalSurface) async {
        guard !surface.hasLiveSurface else { return }
        let previousOnRuntimeReady = surface.onRuntimeReady
        defer { surface.onRuntimeReady = previousOnRuntimeReady }
        let readiness = AsyncStream<Void> { continuation in
            surface.onRuntimeReady = {
                previousOnRuntimeReady?()
                continuation.yield()
                continuation.finish()
            }
        }
        for await _ in readiness { break }
    }

    @MainActor
    static func dispatch(
        _ shortcut: AppStoredShortcut,
        in harness: Harness,
        isARepeat: Bool = false
    ) -> Bool {
        guard let event = event(shortcut, in: harness, isARepeat: isARepeat) else {
            return false
        }
#if DEBUG
        return harness.appDelegate.debugHandleCustomShortcut(event: event)
#else
        return false
#endif
    }

    static func event(
        _ shortcut: AppStoredShortcut,
        in harness: Harness,
        isARepeat: Bool = false
    ) -> NSEvent? {
        guard !shortcut.isUnbound,
              !shortcut.hasChord,
              let keyCode = shortcut.firstStroke.resolvedKeyCode() else {
            return nil
        }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shortcut.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber,
            context: nil,
            characters: shortcut.menuItemKeyEquivalent ?? shortcut.key,
            charactersIgnoringModifiers: shortcut.menuItemKeyEquivalent ?? shortcut.key,
            isARepeat: isARepeat,
            keyCode: keyCode
        )
    }

    static func customShortcut(key: String) -> AppStoredShortcut {
        AppStoredShortcut(
            key: key,
            command: true,
            shift: false,
            option: true,
            control: true
        )
    }

    static func splitNodes(in node: ExternalTreeNode) -> [ExternalSplitNode] {
        switch node {
        case .pane:
            []
        case .split(let split):
            [split] + splitNodes(in: split.first) +
                splitNodes(in: split.second)
        }
    }
}

@MainActor
private final class DockShortcutTestPanel: Panel, ObservableObject {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .terminal
    let displayTitle = "Dock Shortcut Test Panel"
    let displayIcon: String? = "terminal.fill"
    var isDirty = false
    private(set) var flashReasons: [WorkspaceAttentionFlashReason] = []

    func close() {}
    func focus() {}
    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        flashReasons.append(reason)
    }
}

private extension DockSplitStore {
    @MainActor
    func seedShortcutTestPanel(inPane pane: PaneID) throws -> DockShortcutTestPanel {
        let panel = DockShortcutTestPanel()
        panels[panel.id] = panel
        let tabId = try #require(
            bonsplitController.createTab(
                title: panel.displayTitle,
                icon: panel.displayIcon,
                kind: "terminal",
                isDirty: panel.isDirty,
                inPane: pane
            )
        )
        surfaceIdToPanelId[tabId] = panel.id
        bonsplitController.focusPane(pane)
        bonsplitController.selectTab(tabId)
        applyDockSelection(tabId: tabId, inPane: pane)
        return panel
    }

    @MainActor
    func seedSimulatorPanel(inPane pane: PaneID) throws -> SimulatorPanel {
        let panel = SimulatorPanel()
        panels[panel.id] = panel
        let tabId = try #require(
            bonsplitController.createTab(
                title: panel.displayTitle,
                icon: panel.displayIcon,
                kind: SurfaceKind.simulator.rawValue,
                isDirty: panel.isDirty,
                inPane: pane
            )
        )
        surfaceIdToPanelId[tabId] = panel.id
        bonsplitController.focusPane(pane)
        bonsplitController.selectTab(tabId)
        applyDockSelection(tabId: tabId, inPane: pane)
        return panel
    }
}

@MainActor
private final class DockSimulatorResponder: NSView, SimulatorInputResponder {
    let simulatorOwnerID: ObjectIdentifier?

    init(owner: ObjectIdentifier) {
        simulatorOwnerID = owner
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
}
