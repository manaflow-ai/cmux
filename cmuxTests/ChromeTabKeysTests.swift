import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Classic's Chrome tab keys (Leo 2026-10-12) select sidebar workspaces, what Chrome calls tabs,
/// even from a pane with two tabs: Ctrl-Tab and Cmd-Shift-] the next, Ctrl-Shift-Tab and
/// Cmd-Shift-[ the previous, Cmd-1…8 the nth and Cmd-9 the last. Each key goes through the app's
/// shortcut dispatch as the event a keyboard (or Leo's Karabiner) sends: Shift-] types "}".
@MainActor
final class ChromeTabKeysTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore?

    override func setUpWithError() throws {
        try super.setUpWithError()
        executionTimeAllowance = 30
        originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "cmux-chrome-tab-keys")
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

    private static func functionKey(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt32(key))!))
    }

    /// Proposed (needs a call, #13742): Chrome's other tab keys, Ctrl-PageDown/PageUp and
    /// Cmd-Opt-→/←, also select sidebar workspaces; Focus Pane Left/Right moves to Ctrl-Cmd-H/L.
    func testProposedChromeTabKeysSelectASidebarWorkspaceFromATwoTabPane() throws {
        #if DEBUG
        try assertSidebarKeys { order in
            [
                (Key(name: "Ctrl-PageDown", flags: [.control, .function], characters: Self.functionKey(NSPageDownFunctionKey), keyCode: 121), order[2]),
                (Key(name: "Ctrl-PageUp", flags: [.control, .function], characters: Self.functionKey(NSPageUpFunctionKey), keyCode: 116), order[0]),
                (Key(name: "Cmd-Opt-→", flags: [.command, .option, .function, .numericPad], characters: Self.functionKey(NSRightArrowFunctionKey), keyCode: 124), order[2]),
                (Key(name: "Cmd-Opt-←", flags: [.command, .option, .function, .numericPad], characters: Self.functionKey(NSLeftArrowFunctionKey), keyCode: 123), order[0]),
            ]
        }
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.focusLeft.defaultShortcut,
            StoredShortcut(key: "h", command: true, shift: false, option: false, control: true)
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.focusRight.defaultShortcut,
            StoredShortcut(key: "l", command: true, shift: false, option: false, control: true)
        )
        #else
        throw XCTSkip("debugHandleCustomShortcut is only available in DEBUG builds")
        #endif
    }

    func testEveryChromeTabKeySelectsASidebarWorkspaceFromATwoTabPane() throws {
        #if DEBUG
        try assertSidebarKeys { order in
            [
                (Key(name: "Ctrl-Tab", flags: [.control], characters: "\t", keyCode: 48), order[2]),
                (Key(name: "Ctrl-Shift-Tab", flags: [.control, .shift], characters: "\u{19}", keyCode: 48), order[0]),
                (Key(name: "Cmd-Shift-]", flags: [.command, .shift], characters: "}", keyCode: 30), order[2]),
                (Key(name: "Cmd-Shift-[", flags: [.command, .shift], characters: "{", keyCode: 33), order[0]),
                (Key(name: "Cmd-1", flags: [.command], characters: "1", keyCode: 18), order[0]),
                (Key(name: "Cmd-3", flags: [.command], characters: "3", keyCode: 20), order[2]),
                (Key(name: "Cmd-9", flags: [.command], characters: "9", keyCode: 25), order[3]),
            ]
        }
        #else
        throw XCTSkip("debugHandleCustomShortcut is only available in DEBUG builds")
        #endif
    }

    #if DEBUG
    /// Sends each key from the second of four workspaces, whose focused pane has two tabs, and
    /// expects the paired sidebar workspace with the pane's tab left alone.
    private func assertSidebarKeys(_ cases: ([UUID]) -> [(Key, UUID)]) throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(windowId) }
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let window = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "cmux.main.\(windowId.uuidString)" })
        for title in ["Build", "Logs", "Docs"] { _ = manager.addWorkspace(title: title, select: false) }
        let order = manager.tabs.map(\.id)
        XCTAssertEqual(order.count, 4)
        let start = try XCTUnwrap(manager.tabs.first { $0.id == order[1] })
        let pane = try XCTUnwrap(start.bonsplitController.allPaneIds.first)
        _ = try XCTUnwrap(start.newTerminalSurface(inPane: pane, focus: false))
        let panels = start.sidebarOrderedPanelIds()
        XCTAssertEqual(panels.count, 2)

        for (key, expected) in cases(order) {
            manager.selectWorkspace(start)
            start.focusPanel(panels[0])
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: key.flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode
            ))
            XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: event), "\(key.name) is an app shortcut")
            XCTAssertEqual(manager.selectedTabId, expected, "\(key.name) selects the sidebar workspace, not the pane's other tab")
            XCTAssertEqual(start.focusedPanelId, panels[0], "\(key.name) leaves the pane's tab alone")
        }
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
