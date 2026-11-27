import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A local terminal becomes a shared-sizing host the first time a phone or a
/// socket client asks for its size state. Closing the terminal left the host,
/// its sharing controller and its store snapshot registered forever, so every
/// later phone keystroke kept resolving the closed surface.
@MainActor
@Suite("Local shared sizing host", .serialized)
struct LocalTerminalSizingHostLifecycleTests {
    @Test func closingASharedTerminalDropsItsSizingHost() async throws {
        try await withAppContext { workspace in
            let controller = TerminalController.shared
            defer { controller.resetLocalSizingHosts() }
            let panel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
            try #require(controller.terminalSocketTarget(surfaceID: panel.id) != nil)
            try #require(controller.localSizingHost(surfaceID: panel.id, create: true) != nil)
            #expect(controller.terminalSharing.snapshot(for: panel.id) != nil)

            #expect(workspace.closePanel(panel.id, force: true))
            for _ in 0..<50 where workspace.panels[panel.id] != nil {
                await Task.yield()
            }
            try #require(workspace.panels[panel.id] == nil)

            #expect(controller.localSizingHost(surfaceID: panel.id, create: false) == nil)
            #expect(controller.localSizingControllersBySurfaceID[panel.id] == nil)
            #expect(controller.terminalSharing.snapshot(for: panel.id) == nil)
        }
    }

    /// The size panel bounds a fixed grid to 500 x 200, but the socket
    /// accepted any size: a local pane was capped to it, and a Cloud daemon
    /// failed to decode a value above 65535 while the CLI reported success.
    @Test func socketRejectsAFixedSizeAboveTheLimit() async throws {
        try await withAppContext { workspace in
            let controller = TerminalController.shared
            defer { controller.resetLocalSizingHosts() }
            let panelId = try #require(workspace.focusedPanelId)
            try #require(controller.terminalSocketTarget(surfaceID: panelId) != nil)
            try #require(controller.localSizingHost(surfaceID: panelId, create: true) != nil)
            let before = controller.terminalSharing.snapshot(for: panelId)?.state.policy

            let result = controller.v2TerminalSizePolicySet(params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
                "mode": "fixed",
                "fixed_cols": 70_000,
                "fixed_rows": 40,
            ])
            guard case .err(let code, _, _) = result else {
                Issue.record("Expected invalid_params, got \(result)")
                return
            }
            #expect(code == "invalid_params")
            #expect(controller.terminalSharing.snapshot(for: panelId)?.state.policy == before)
        }
    }

    private func withAppContext(
        _ body: @MainActor (Workspace) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            // Socket targets resolve surfaces through the main window contexts.
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            TerminalController.shared.setActiveTabManager(manager)
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                TerminalController.shared.setActiveTabManager(previousManager)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            try await body(workspace)
        }
    }
}
