import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Command palette static action APIs", .serialized)
struct CommandPaletteStaticActionAPITests {
    @Test
    func nonInteractivePanelCloseHonorsTheExplicitBackgroundPanel() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        let backgroundPanelID = try #require(workspace.focusedPanelId)
        let selectedPanel = try #require(
            workspace.newTerminalSurfaceInFocusedPane(focus: true, initialInput: nil)
        )
        #expect(workspace.focusedPanelId == selectedPanel.id)

        #expect(manager.closePanelNonInteractively(
            workspaceID: workspace.id,
            panelID: backgroundPanelID,
            allowPinnedWorkspace: true
        ))

        #expect(workspace.panels[backgroundPanelID] == nil)
        #expect(workspace.panels[selectedPanel.id] != nil)
        #expect(workspace.focusedPanelId == selectedPanel.id)
    }

    @Test
    func nonInteractiveWorkspaceBatchPrevalidatesTheExactSet() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(manager.tabs.first)
        let pinnedWorkspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let survivor = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        pinnedWorkspace.isPinned = true

        #expect(!manager.closeWorkspacesNonInteractively(
            [pinnedWorkspace.id, UUID()],
            allowPinned: true
        ))
        #expect(manager.tabs.contains(where: { $0.id == pinnedWorkspace.id }))

        #expect(manager.closeWorkspacesNonInteractively(
            [pinnedWorkspace.id],
            allowPinned: true
        ))
        #expect(!manager.tabs.contains(where: { $0.id == pinnedWorkspace.id }))
        #expect(manager.tabs.contains(where: { $0.id == survivor.id }))
        #expect(manager.selectedWorkspace?.id == selectedWorkspace.id)
    }

    @Test
    func explicitTextBoxAttachmentFlushesWhenTheViewMounts() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        let panel = try #require(workspace.focusedTerminalPanel)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-palette-attachment-\(UUID().uuidString).txt")
        try Data("fixture".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        #expect(panel.attachFilesToTextBoxInput([fileURL]) == .queued)

        let view = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        var attachedURLs: [URL] = []
        view.onInsertFileURLs = { urls, _ in
            attachedURLs = urls
            return true
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        defer { window.close() }

        panel.registerTextBoxInputView(view)
        panel.textBoxInputViewDidMoveToWindow(view)

        #expect(attachedURLs == [fileURL.standardizedFileURL])
    }
}
