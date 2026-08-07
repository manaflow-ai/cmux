import AppKit
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceDragSplitFocusSwiftTests {
#if DEBUG
    @Test
    func movedTerminalBecomesSoleFocusedCursor() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer { AppDelegate.shared = originalAppDelegate }

        let workspace = Workspace()
        let originalPanelId = try #require(workspace.focusedPanelId)
        let originalPanel = try #require(workspace.terminalPanel(for: originalPanelId))
        let sourcePane = try #require(workspace.paneId(forPanelId: originalPanelId))
        let movedPanel = try #require(
            workspace.newTerminalSurface(inPane: sourcePane, focus: false)
        )
        let movedTab = try #require(workspace.surfaceIdFromPanelId(movedPanel.id))

        let window = makeWindow()
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView, "Expected content view")

        originalPanel.hostedView.frame = contentView.bounds
        movedPanel.hostedView.frame = contentView.bounds
        contentView.addSubview(originalPanel.hostedView)
        contentView.addSubview(movedPanel.hostedView)
        originalPanel.hostedView.setVisibleInUI(true)
        movedPanel.hostedView.setVisibleInUI(true)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        originalPanel.hostedView.layoutSubtreeIfNeeded()
        movedPanel.hostedView.layoutSubtreeIfNeeded()

        workspace.focusPanel(originalPanelId)
        #expect(originalPanel.surface.debugDesiredFocusState())
        #expect(!movedPanel.surface.debugDesiredFocusState())

        let newPane = try #require(
            workspace.bonsplitController.splitPane(
                sourcePane,
                orientation: .vertical,
                movingTab: movedTab,
                insertFirst: false
            )
        )

        #expect(workspace.bonsplitController.focusedPaneId == newPane)
        #expect(workspace.focusedPanelId == movedPanel.id)
        #expect(!originalPanel.surface.debugDesiredFocusState())
        #expect(movedPanel.surface.debugDesiredFocusState())
    }
#endif

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }
}
