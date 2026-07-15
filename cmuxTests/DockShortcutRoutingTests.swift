import AppKit
import Bonsplit
import Combine
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Dock shortcut routing", .serialized)
struct DockShortcutRoutingTests {
    @Test("Customized next-surface shortcut targets the focused Dock")
    @MainActor
    func customizedNextSurfaceTargetsFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try Self.withHarness { harness in
                let firstPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                let secondPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                harness.dock.focusPanel(firstPanel)
                let mainPanelBefore = harness.mainWorkspace.focusedPanelId

                let customShortcut = StoredShortcut(
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
            try Self.withHarness { harness in
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

                let customShortcut = StoredShortcut(
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
            try Self.withHarness { harness in
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

                let next = StoredShortcut(
                    key: "\t",
                    command: false,
                    shift: false,
                    option: false,
                    control: true
                )
                #expect(Self.dispatch(next, in: harness))
                #expect(harness.dock.focusedPanelId == secondPanel)

                let previous = StoredShortcut(
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
            try Self.withHarness { harness in
                let firstPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                _ = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                harness.dock.focusPanel(firstPanel)

                let controlTab = StoredShortcut(
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
            try Self.withHarness { harness in
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
            try Self.withHarness { harness in
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
            try Self.withHarness { harness in
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

                let numberedShortcut = StoredShortcut(
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
            try Self.withHarness { harness in
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
            try Self.withHarness { harness in
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
                #expect(panel.flashCount == 1)
                #expect(harness.mainWorkspace.focusedPanelId == mainPanelBefore)
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
        let rootPane: PaneID
        let window: NSWindow
    }

    @MainActor
    static func withHarness(_ body: (Harness) throws -> Void) throws {
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-dock-shortcut-routing"
        )
        KeyboardShortcutSettings.resetAll()

        let appDelegate = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
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
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            TerminalController.shared.setActiveTabManager(previousManager)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            window.orderOut(nil)
            window.close()
            AppDelegate.shared = previousAppDelegate
        }

        try body(Harness(
            appDelegate: appDelegate,
            dock: dock,
            mainWorkspace: mainWorkspace,
            rootPane: rootPane,
            window: window
        ))
    }

    @MainActor
    static func dispatch(_ shortcut: StoredShortcut, in harness: Harness) -> Bool {
        guard !shortcut.isUnbound,
              !shortcut.hasChord,
              let keyCode = shortcut.firstStroke.resolvedKeyCode(),
              let event = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: shortcut.modifierFlags,
                  timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: harness.window.windowNumber,
                  context: nil,
                  characters: shortcut.menuItemKeyEquivalent ?? shortcut.key,
                  charactersIgnoringModifiers: shortcut.menuItemKeyEquivalent ?? shortcut.key,
                  isARepeat: false,
                  keyCode: keyCode
              ) else {
            return false
        }
#if DEBUG
        return harness.appDelegate.debugHandleCustomShortcut(event: event)
#else
        return false
#endif
    }

    static func customShortcut(key: String) -> StoredShortcut {
        StoredShortcut(
            key: key,
            command: true,
            shift: false,
            option: true,
            control: true
        )
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
    private(set) var flashCount = 0

    func close() {}
    func focus() {}
    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        flashCount += 1
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
}
