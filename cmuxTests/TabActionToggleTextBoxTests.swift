import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux tab-action --action toggle-text-box` toggles a terminal's TextBox Input from
/// scripts, like the Toggle TextBox Input command (https://github.com/manaflow-ai/cmux/issues/22308).
@MainActor
@Suite(.serialized, .exclusiveAppContext)
struct TabActionToggleTextBoxTests {
    /// Sends one v2 request the way a socket client does and returns its envelope.
    private func send(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let request: [String: Any] = ["id": method, "method": method, "params": params]
        let line = try #require(String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(line)
        return try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    /// A script toggling another pane's TextBox must not move keyboard focus there:
    /// socket commands only focus when asked to.
    @Test func toggleTextBoxOnAnUnfocusedPaneKeepsFocusWhereItIs() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow(shouldActivate: false)
        defer { appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId) }
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanelId = try #require(workspace.focusedPanelId)
        let other = try #require(workspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal, focus: false))
        try #require(workspace.focusedPanelId == focusedPanelId)

        let params: [String: Any] = [
            "action": "toggle_text_box",
            "workspace_id": workspace.id.uuidString,
            "surface_id": other.id.uuidString,
        ]
        let opened = try send("surface.action", params)
        #expect(opened["ok"] as? Bool == true, "\(opened)")
        #expect(other.isTextBoxActive)
        #expect(workspace.focusedPanelId == focusedPanelId)
        #expect(other.textBoxInputFocusIntent != .textBox && !other.shouldFocusTextBoxWhenAvailable,
                "opening another pane's TextBox takes keyboard focus")

        let window = try #require(appDelegate.mainWindow(for: windowId))
        let closed = try send("surface.action", params)
        #expect(closed["ok"] as? Bool == true, "\(closed)")
        #expect(!other.isTextBoxActive)
        #expect(workspace.focusedPanelId == focusedPanelId)
        let responder = window.firstResponder as? NSView
        #expect(responder?.isDescendant(of: other.hostedView) != true,
                "closing another pane's TextBox focused its terminal")
    }

    /// With focus requested, the toggle selects the target pane and gives its
    /// TextBox the keyboard, like the Toggle TextBox Input command.
    @Test func toggleTextBoxWithFocusSelectsTheTargetPane() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow(shouldActivate: false)
        defer { appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId) }
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanelId = try #require(workspace.focusedPanelId)
        let other = try #require(workspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal, focus: false))
        try #require(workspace.focusedPanelId == focusedPanelId)

        let opened = try send("surface.action", [
            "action": "toggle_text_box",
            "workspace_id": workspace.id.uuidString,
            "surface_id": other.id.uuidString,
            "focus": true,
        ])
        #expect(opened["ok"] as? Bool == true, "\(opened)")
        #expect(other.isTextBoxActive)
        #expect(other.textBoxInputFocusIntent == .textBox)
        #expect(workspace.focusedPanelId == other.id, "the focused toggle left another pane selected")
    }

    @Test func toggleTextBoxOpensAndClosesTheTerminalsTextBox() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow(shouldActivate: false)
        defer { appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId) }
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let terminal = try #require(workspace.terminalPanel(for: panelId))
        try #require(!terminal.isTextBoxActive)

        let params: [String: Any] = [
            "action": "toggle_text_box",
            "workspace_id": workspace.id.uuidString,
            "surface_id": panelId.uuidString,
        ]
        let opened = try send("surface.action", params)
        #expect(opened["ok"] as? Bool == true, "surface.action toggle_text_box failed: \(opened)")
        #expect(terminal.isTextBoxActive)
        #expect((opened["result"] as? [String: Any])?["text_box_visible"] as? Bool == true)

        let closed = try send("surface.action", params)
        #expect(closed["ok"] as? Bool == true, "\(closed)")
        #expect(!terminal.isTextBoxActive)
        #expect((closed["result"] as? [String: Any])?["text_box_visible"] as? Bool == false)
    }
}
