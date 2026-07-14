import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct AgentHibernationPortalVisibilityTests {
    @Test func staleWorkspaceContentDisappearanceKeepsReplacementPresentationVisible() async throws {
        _ = NSApplication.shared
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        var firstAppeared = false
        var replacementAppeared = false
        var firstDisappeared = false

        let firstWindow = makeWorkspaceWindow(
            workspace: workspace,
            onAppear: { firstAppeared = true },
            onDisappear: { firstDisappeared = true }
        )
        let replacementWindow = makeWorkspaceWindow(
            workspace: workspace,
            onAppear: { replacementAppeared = true },
            onDisappear: {}
        )
        defer {
            firstWindow.contentView = nil
            replacementWindow.contentView = nil
            firstWindow.close()
            replacementWindow.close()
        }

        #expect(await waitUntil { firstAppeared && replacementAppeared })
        firstWindow.contentView = nil
        #expect(await waitUntil { firstDisappeared })
        await Task.yield()

        #expect(workspace.portalPresentationVisible)
        #expect(workspace.agentHibernationVisiblePanelIdsForCurrentLayout().contains(panelId))
    }

    @Test func showingAutoResumePresentationDoesNotRestoreNonHibernatedTerminalPortal() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))

        #expect(!panel.isAgentHibernated)
        panel.hostedView.setVisibleInUI(false)
        #expect(!panel.hostedView.debugPortalVisibleInUI)

        workspace.setAgentHibernationAutoResumePresentationVisible(false)
        workspace.setAgentHibernationAutoResumePresentationVisible(true)

        #expect(!panel.hostedView.debugPortalVisibleInUI)
    }

    private func makeWorkspaceWindow(
        workspace: Workspace,
        onAppear: @escaping () -> Void,
        onDisappear: @escaping () -> Void
    ) -> NSWindow {
        let root = AnyView(
            WorkspaceContentView(
                workspace: workspace,
                isWorkspaceVisible: true,
                isWorkspaceInputActive: true,
                isFullScreen: false,
                workspacePortalPriority: 2,
                windowAppearance: .rightSidebarPanelViewTestDefault,
                onThemeRefreshRequest: nil
            )
            .environmentObject(TerminalNotificationStore.shared)
            .onAppear(perform: onAppear)
            .onDisappear(perform: onDisappear)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: root)
        return window
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
