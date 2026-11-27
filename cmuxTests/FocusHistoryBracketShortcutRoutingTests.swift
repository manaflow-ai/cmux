import AppKit
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
private typealias AppStoredShortcut = cmux_DEV.StoredShortcut
#elseif canImport(cmux)
@testable import cmux
private typealias AppStoredShortcut = cmux.StoredShortcut
#endif

/// Regression: Cmd+[ / Cmd+] must reach the focus-history branch of the
/// shortcut dispatch even though the mirrored Ghostty goto_split:previous/next
/// triggers sit on the same keys (Ghostty's macOS defaults) and are checked
/// earlier. Before the fix the mirror consumed the keys unconditionally, so the
/// shortcut cycled panes inside the current workspace while the titlebar arrow
/// buttons (same `TabManager.navigateBack()/navigateForward()` model) navigated
/// across workspaces.
@Suite("Focus history bracket shortcut routing", .serialized)
struct FocusHistoryBracketShortcutRoutingTests {
    @Test("Cmd+[ / Cmd+] navigate workspace focus history despite the Ghostty goto_split mirror")
    @MainActor
    func bracketsNavigateWorkspaceHistoryDespiteGotoSplitMirror() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try Self.withHarness { harness in
                // Mirror Ghostty's macOS defaults: goto_split:previous/next on ⌘[ / ⌘].
                harness.appDelegate.ghosttyGotoSplitPreviousShortcut = Self.commandBracketShortcut("[")
                harness.appDelegate.ghosttyGotoSplitNextShortcut = Self.commandBracketShortcut("]")

                let firstWorkspace = harness.firstWorkspace
                let secondWorkspace = harness.tabManager.addWorkspace(select: true, eagerLoadTerminal: false)
                #expect(harness.tabManager.selectedTabId == secondWorkspace.id)

                #expect(Self.dispatch(Self.commandBracketShortcut("["), in: harness))
                #expect(
                    harness.tabManager.selectedTabId == firstWorkspace.id,
                    "Cmd+[ must walk focus history back across workspaces, not cycle panes"
                )

                #expect(Self.dispatch(Self.commandBracketShortcut("]"), in: harness))
                #expect(
                    harness.tabManager.selectedTabId == secondWorkspace.id,
                    "Cmd+] must walk focus history forward across workspaces"
                )
            }
        }
    }

    @Test("Unbinding Focus Back/Forward hands the bracket keys back to the goto_split mirror")
    @MainActor
    func unboundFocusHistoryYieldsBracketsToGotoSplitMirror() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try Self.withHarness { harness in
                harness.appDelegate.ghosttyGotoSplitPreviousShortcut = Self.commandBracketShortcut("[")
                harness.appDelegate.ghosttyGotoSplitNextShortcut = Self.commandBracketShortcut("]")

                _ = harness.tabManager.addWorkspace(select: true, eagerLoadTerminal: false)
                let selectedBefore = harness.tabManager.selectedTabId

                KeyboardShortcutSettings.clearShortcut(for: .focusHistoryBack)
                KeyboardShortcutSettings.clearShortcut(for: .focusHistoryForward)

                #expect(
                    Self.dispatch(Self.commandBracketShortcut("["), in: harness),
                    "The goto_split mirror should still consume ⌘[ once focus history is unbound"
                )
                #expect(
                    harness.tabManager.selectedTabId == selectedBefore,
                    "Pane cycling stays inside the current workspace"
                )
            }
        }
    }

    /// With no Dock focused, both shortcuts fall through to the main window's
    /// TabManager; the default workspace-only scope doesn't limit either one.
    @Test("Focus Last Surface and Focus Last Workspace shortcuts toggle in the main area")
    @MainActor
    func focusLastSurfaceAndWorkspaceShortcutsToggleInMainArea() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try Self.withHarness { harness in
                let firstWorkspace = harness.firstWorkspace
                let pane = try #require(firstWorkspace.bonsplitController.allPaneIds.first)
                let firstPanelId = try #require(firstWorkspace.focusedPanelId)
                let secondPanelId = try #require(firstWorkspace.newTerminalSurface(inPane: pane, focus: true)?.id)
                firstWorkspace.focusPanel(firstPanelId)
                FocusSurfaceBroadcaster.shared.flush()
                firstWorkspace.focusPanel(secondPanelId)
                FocusSurfaceBroadcaster.shared.flush()

                let lastSurface = Self.customShortcut(key: "y")
                let lastWorkspace = Self.customShortcut(key: "u")
                KeyboardShortcutSettings.setShortcut(lastSurface, for: .focusHistoryLastSurface)
                KeyboardShortcutSettings.setShortcut(lastWorkspace, for: .focusHistoryLastWorkspace)

                #expect(Self.dispatch(lastSurface, in: harness))
                FocusSurfaceBroadcaster.shared.flush()
                #expect(firstWorkspace.focusedPanelId == firstPanelId)

                let secondWorkspace = harness.tabManager.addWorkspace(select: true, eagerLoadTerminal: false)
                #expect(Self.dispatch(lastWorkspace, in: harness))
                FocusSurfaceBroadcaster.shared.flush()
                #expect(harness.tabManager.selectedTabId == firstWorkspace.id)
                #expect(firstWorkspace.focusedPanelId == firstPanelId)

                #expect(Self.dispatch(lastWorkspace, in: harness))
                #expect(harness.tabManager.selectedTabId == secondWorkspace.id)
            }
        }
    }

    /// The History menu's entrypoint for Focus Last Surface, with no Dock focused.
    @Test("Focus Last Surface's menu action toggles the main area with no Dock focused")
    @MainActor
    func focusLastSurfaceMenuActionTogglesMainArea() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try Self.withHarness { harness in
                let workspace = harness.firstWorkspace
                let pane = try #require(workspace.bonsplitController.allPaneIds.first)
                let firstPanelId = try #require(workspace.focusedPanelId)
                let secondPanelId = try #require(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
                workspace.focusPanel(firstPanelId)
                FocusSurfaceBroadcaster.shared.flush()
                workspace.focusPanel(secondPanelId)
                FocusSurfaceBroadcaster.shared.flush()

                #expect(harness.appDelegate.performFocusHistoryLastSurfaceShortcut(preferredWindow: harness.window))
                FocusSurfaceBroadcaster.shared.flush()
                #expect(workspace.focusedPanelId == firstPanelId)
                #expect(harness.appDelegate.performFocusHistoryLastSurfaceShortcut(preferredWindow: harness.window))
                FocusSurfaceBroadcaster.shared.flush()
                #expect(workspace.focusedPanelId == secondPanelId)
            }
        }
    }

    // MARK: - Harness (main-area sibling of DockShortcutRoutingTests.withHarness)

    struct Harness {
        let appDelegate: AppDelegate
        let tabManager: TabManager
        let firstWorkspace: Workspace
        let window: NSWindow
    }

    @MainActor
    static func withHarness(_ body: (Harness) throws -> Void) throws {
        let previousAppDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-focus-history-bracket-routing"
        )
        KeyboardShortcutSettings.resetAll()

        let appDelegate = AppDelegate()
        let suiteName = "FocusHistoryBracketShortcutRoutingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let manager = TabManager(autoWelcomeIfNeeded: false, settings: settings)
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
            fileExplorerState: FileExplorerState()
        )
        window.makeKeyAndOrderFront(nil)

        let firstWorkspace = try #require(manager.tabs.first)

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

        try body(Harness(
            appDelegate: appDelegate,
            tabManager: manager,
            firstWorkspace: firstWorkspace,
            window: window
        ))
    }

    fileprivate static func commandBracketShortcut(_ key: String) -> AppStoredShortcut {
        AppStoredShortcut(key: key, command: true, shift: false, option: false, control: false)
    }

    fileprivate static func customShortcut(key: String) -> AppStoredShortcut {
        AppStoredShortcut(key: key, command: true, shift: false, option: true, control: true)
    }

    @MainActor
    fileprivate static func dispatch(_ shortcut: AppStoredShortcut, in harness: Harness) -> Bool {
        guard let keyCode = shortcut.firstStroke.resolvedKeyCode() else { return false }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shortcut.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber,
            context: nil,
            characters: shortcut.key,
            charactersIgnoringModifiers: shortcut.key,
            isARepeat: false,
            keyCode: keyCode
        ) else { return false }
#if DEBUG
        return harness.appDelegate.debugHandleCustomShortcut(event: event)
#else
        return false
#endif
    }
}
