import AppKit
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
}
