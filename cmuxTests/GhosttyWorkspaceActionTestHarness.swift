import AppKit
import CmuxTerminal
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Runs real Ghostty bindings against a registered, independently owned window.
@MainActor
final class GhosttyWorkspaceActionTestHarness {
    let app: AppDelegate
    let manager: TabManager
    let window: NSWindow
    let windowID = UUID()
    let sourceWorkspaceID: UUID
    private let previousManager: TabManager?

    init() throws {
        app = try #require(AppDelegate.shared)
        manager = TabManager(autoWelcomeIfNeeded: false)
        sourceWorkspaceID = try #require(manager.selectedTabId)
        previousManager = app.tabManager
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        app.registerMainWindow(
            window, windowId: windowID, tabManager: manager,
            sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.tabManager = manager
    }

    func close() {
        window.orderOut(nil)
        app.unregisterMainWindowContextForTesting(windowId: windowID)
        app.forgetRecoverableMainWindowRoute(windowId: windowID)
        manager.finalizeAllWorkspacesForWindowClose()
        app.tabManager = previousManager
        window.close()
    }

    func startTerminal() async throws -> TerminalSurface {
        let workspace = try #require(manager.tabs.first(where: { $0.id == self.sourceWorkspaceID }))
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))
        let content = try #require(window.contentView)
        manager.selectWorkspace(workspace)
        workspace.setPortalRenderingEnabled(true, reason: "ghostty-workspace-actions-test")
        panel.hostedView.frame = content.bounds
        content.addSubview(panel.hostedView)
        panel.hostedView.setVisibleInUI(true)
        panel.hostedView.setActive(true)
        window.makeKeyAndOrderFront(nil)
        app.setActiveMainWindow(window)
        window.displayIfNeeded()
        content.layoutSubtreeIfNeeded()
        panel.hostedView.layoutSubtreeIfNeeded()
        await AppKitTestEventPump().startSurface(panel.surface)
        try #require(panel.surface.hasLiveSurface)
        return panel.surface
    }

    func configure(_ surface: TerminalSurface, contents: String) throws {
        let base = try #require(GhosttyApp.shared.config)
        let config = try #require(ghostty_config_clone(base))
        defer { ghostty_config_free(config) }
        contents.withCString { pointer in
            ghostty_config_load_string(config, pointer, UInt(contents.utf8.count), "/__cmux_test__/14462.conf")
        }
        ghostty_config_finalize(config)
        #expect(ghostty_config_diagnostics_count(config) == 0)
        ghostty_surface_update_config(try #require(surface.surface), config)
    }

    func press(
        _ text: String, keyCode: UInt32, control: Bool = false,
        on surface: TerminalSurface
    ) -> Bool {
        guard let runtime = surface.surface else { return false }
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.keycode = keyCode
        event.mods = control ? GHOSTTY_MODS_CTRL : GHOSTTY_MODS_NONE
        event.unshifted_codepoint = text.unicodeScalars.first?.value ?? 0
        return text.withCString { pointer in
            event.text = pointer
            let handled = ghostty_surface_key(runtime, event)
            event.action = GHOSTTY_ACTION_RELEASE
            _ = ghostty_surface_key(runtime, event)
            return handled
        }
    }
}
