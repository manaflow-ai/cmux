import AppKit
import CmuxCommandPalette
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Command palette terminal toggle outcomes", .serialized)
struct CommandPaletteTerminalToggleOutcomeTests {
    @Test func terminalTogglesDeclareOptionalBooleanEnabled() throws {
        let argument = try #require(ContentView.commandPaletteOptionalEnabledArguments.first)

        #expect(ContentView.commandPaletteOptionalEnabledArguments.count == 1)
        #expect(argument.name == "enabled")
        #expect(argument.valueType == .boolean)
        #expect(!argument.required)
    }

    @Test func textBoxFocusIsIdempotentWhileMountIsPending() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.teardownSurface() }

        #expect(panel.preferTextBoxInputWhenActivated() == .queued)
        #expect(panel.isTextBoxActive)
#if DEBUG
        #expect(panel.debugHasPendingTextBoxFocusRequest)
#endif

        #expect(panel.preferTextBoxInputWhenActivated() == .queued)
        #expect(panel.isTextBoxActive)
#if DEBUG
        #expect(panel.debugHasPendingTextBoxFocusRequest)
#endif
    }

    @Test func mountedTextBoxFocusRemainsIdempotent() {
        let panel = TerminalPanel(workspaceId: UUID())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        let textView = TextBoxInputTextView(frame: scrollView.bounds)
        window.contentView?.addSubview(scrollView)
        scrollView.documentView = textView
        panel.registerTextBoxInputView(textView)
        defer {
            window.close()
            panel.surface.teardownSurface()
        }

        #expect(textView.window === window)
        #expect(panel.preferTextBoxInputWhenActivated() == .focused)
        #expect(window.firstResponder === textView)
        #expect(panel.preferTextBoxInputWhenActivated() == .focused)
        #expect(window.firstResponder === textView)
        #expect(panel.isTextBoxActive)
    }

    @Test func textBoxOutcomesPreserveFocusedQueuedHiddenAndFailedStates() {
        #expect(ContentView.commandPaletteTerminalTextBoxResult(.focused) == .presented)
        #expect(ContentView.commandPaletteTerminalTextBoxResult(.queued) == .queued)
        #expect(ContentView.commandPaletteTerminalTextBoxResult(.hidden) == .completed)
        #expect(ContentView.commandPaletteTerminalTextBoxResult(.failed) == .failed(
            code: "terminal_text_box_focus_failed",
            message: String(
                localized: "action.error.terminalActionFailed",
                defaultValue: "The terminal action could not be completed."
            )
        ))
    }

    @Test func textBoxExplicitStateIsIdempotentAndOmittedToggleStillFlips() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.teardownSurface() }

        #expect(panel.setTextBoxInputEnabled(true) == .queued)
        #expect(panel.setTextBoxInputEnabled(true) == .queued)
        #expect(panel.isTextBoxActive)
        #expect(panel.setTextBoxInputEnabled(false) == .hidden)
        #expect(panel.setTextBoxInputEnabled(false) == .hidden)
        #expect(!panel.isTextBoxActive)

        #expect(panel.toggleTextBoxInput())
        #expect(panel.isTextBoxActive)
        #expect(panel.toggleTextBoxInput())
        #expect(!panel.isTextBoxActive)
    }

    @Test func splitZoomExplicitStateIsIdempotentAndToggleStillFlips() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let leftPanelID = try #require(workspace.focusedPanelId)
        _ = try #require(
            workspace.newTerminalSplit(from: leftPanelID, orientation: .horizontal)
        )
        let leftPaneID = try #require(workspace.paneId(forPanelId: leftPanelID))

        #expect(manager.setSplitZoom(true, tabId: workspace.id, surfaceId: leftPanelID))
        #expect(workspace.bonsplitController.zoomedPaneId == leftPaneID)
        #expect(manager.setSplitZoom(true, tabId: workspace.id, surfaceId: leftPanelID))
        #expect(workspace.bonsplitController.zoomedPaneId == leftPaneID)
        #expect(manager.setSplitZoom(false, tabId: workspace.id, surfaceId: leftPanelID))
        #expect(workspace.bonsplitController.zoomedPaneId == nil)
        #expect(manager.setSplitZoom(false, tabId: workspace.id, surfaceId: leftPanelID))
        #expect(workspace.bonsplitController.zoomedPaneId == nil)

        #expect(manager.toggleSplitZoom(tabId: workspace.id, surfaceId: leftPanelID))
        #expect(workspace.bonsplitController.zoomedPaneId == leftPaneID)
        #expect(manager.toggleSplitZoom(tabId: workspace.id, surfaceId: leftPanelID))
        #expect(workspace.bonsplitController.zoomedPaneId == nil)
    }

    @Test func fullWidthExplicitStateIsIdempotentAndToggleStillFlips() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: panelID))

        #expect(manager.setFullWidthTab(true, workspaceID: workspace.id, panelID: panelID))
        #expect(workspace.bonsplitController.isFullWidthTabMode(inPane: paneID))
        #expect(manager.setFullWidthTab(true, workspaceID: workspace.id, panelID: panelID))
        #expect(workspace.bonsplitController.isFullWidthTabMode(inPane: paneID))
        #expect(manager.setFullWidthTab(false, workspaceID: workspace.id, panelID: panelID))
        #expect(!workspace.bonsplitController.isFullWidthTabMode(inPane: paneID))
        #expect(manager.setFullWidthTab(false, workspaceID: workspace.id, panelID: panelID))
        #expect(!workspace.bonsplitController.isFullWidthTabMode(inPane: paneID))

        #expect(manager.toggleFullWidthTab(workspaceID: workspace.id, panelID: panelID))
        #expect(workspace.bonsplitController.isFullWidthTabMode(inPane: paneID))
        #expect(manager.toggleFullWidthTab(workspaceID: workspace.id, panelID: panelID))
        #expect(!workspace.bonsplitController.isFullWidthTabMode(inPane: paneID))
    }
}
