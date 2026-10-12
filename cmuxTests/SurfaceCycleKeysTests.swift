import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Default keys, as shipped in 0.65.x: Ctrl-Tab / Ctrl-Shift-Tab and Cmd-Shift-] / Cmd-Shift-[
/// step the focused pane's tabs when it holds two or more, wrapping inside the pane, and
/// Cmd-Ctrl-] / Cmd-Ctrl-[ move between sidebar workspaces. Each key goes through the app's
/// shortcut dispatch as the event a keyboard sends: Shift-] types "}".
@MainActor
final class SurfaceCycleKeysTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore?

    override func setUpWithError() throws {
        try super.setUpWithError()
        executionTimeAllowance = 30
        originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "cmux-surface-cycle-keys")
        KeyboardShortcutSettings.resetAll()
        #if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting()
        #endif
    }

    override func tearDown() {
        if let originalSettingsFileStore {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        }
        KeyboardShortcutSettings.resetAll()
        super.tearDown()
    }

    private struct Key {
        let name: String
        let flags: NSEvent.ModifierFlags
        let characters: String
        let keyCode: UInt16
    }

    func testDefaultSurfaceKeysStepTheFocusedPaneAndWorkspaceKeysMoveTheSidebar() throws {
        #if DEBUG
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(windowId) }
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let window = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "cmux.main.\(windowId.uuidString)" })
        for title in ["Build", "Logs"] { _ = manager.addWorkspace(title: title, select: false) }
        let order = manager.tabs.map(\.id)
        XCTAssertEqual(order.count, 3)
        // The start: the middle workspace, whose focused pane has two tabs.
        let start = try XCTUnwrap(manager.tabs.first { $0.id == order[1] })
        let pane = try XCTUnwrap(start.bonsplitController.allPaneIds.first)
        _ = try XCTUnwrap(start.newTerminalSurface(inPane: pane, focus: false))
        let panels = start.sidebarOrderedPanelIds()
        XCTAssertEqual(panels.count, 2)

        // Surface keys: from the pane's first tab, Next selects the second and Previous wraps to it.
        let surfaceKeys: [Key] = [
            Key(name: "Ctrl-Tab", flags: [.control], characters: "\t", keyCode: 48),
            Key(name: "Ctrl-Shift-Tab", flags: [.control, .shift], characters: "\u{19}", keyCode: 48),
            Key(name: "Cmd-Shift-]", flags: [.command, .shift], characters: "}", keyCode: 30),
            Key(name: "Cmd-Shift-[", flags: [.command, .shift], characters: "{", keyCode: 33),
        ]
        for key in surfaceKeys {
            manager.selectWorkspace(start)
            start.focusPanel(panels[0])
            try dispatch(key, in: window, appDelegate: appDelegate)
            XCTAssertEqual(manager.selectedTabId, order[1], "\(key.name) stays in the workspace")
            XCTAssertEqual(start.focusedPanelId, panels[1], "\(key.name) steps the focused pane's tabs")
        }

        // Workspace keys: move the sidebar and leave the pane's tab alone.
        let workspaceKeys: [(Key, UUID)] = [
            (Key(name: "Cmd-Ctrl-]", flags: [.command, .control], characters: "]", keyCode: 30), order[2]),
            (Key(name: "Cmd-Ctrl-[", flags: [.command, .control], characters: "[", keyCode: 33), order[0]),
        ]
        for (key, expected) in workspaceKeys {
            manager.selectWorkspace(start)
            start.focusPanel(panels[0])
            try dispatch(key, in: window, appDelegate: appDelegate)
            XCTAssertEqual(manager.selectedTabId, expected, "\(key.name) selects the adjacent sidebar workspace")
            XCTAssertEqual(start.focusedPanelId, panels[0], "\(key.name) leaves the pane's tab alone")
        }
        #else
        throw XCTSkip("debugHandleCustomShortcut is only available in DEBUG builds")
        #endif
    }

    #if DEBUG
    private func dispatch(_ key: Key, in window: NSWindow, appDelegate: AppDelegate) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: key.flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode
        ))
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event), "\(key.name) is an app shortcut")
    }
    #endif

    private func closeWindow(_ windowId: UUID) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "cmux.main.\(windowId.uuidString)" }) else { return }
        let appDelegate = AppDelegate.shared
        let original = appDelegate?.debugCloseMainWindowConfirmationHandler
        appDelegate?.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate?.debugCloseMainWindowConfirmationHandler = original }
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
