import Testing
import Foundation
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/6618: a
/// `report_shell_state` report that reaches the app while its workspace is not
/// yet reachable through any window's `TabManager` (the common case during
/// session restore, where the `Workspace` and its panels already exist but have
/// not been inserted into a manager) must be buffered and replayed once the
/// workspace registers. The shell reports each transition once and dedupes
/// locally, so a dropped report otherwise strands `shellState` at `.unknown`.
@MainActor
@Suite struct TabManagerShellActivityReplayTests {
    @Test func bufferedShellStateReplaysWhenWorkspaceRegisters() throws {
        let appDelegate = try #require(AppDelegate.shared, "Test host AppDelegate expected")
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        _ = try #require(workspace.terminalPanel(for: panelId), "Expected a terminal panel")
        // Keep the shared AppDelegate buffer clean even if an expectation fails
        // before the replay drains it.
        defer { appDelegate.discardPendingShellActivity(forWorkspaceId: workspace.id) }

        // A standalone manager is not wired into AppDelegate's window routes, so
        // the report cannot resolve the workspace and must take the buffered path
        // — exactly the unreachable condition that occurs mid session-restore.
        #expect(appDelegate.tabManagerFor(tabId: workspace.id) == nil)
        #expect((workspace.panelShellActivityStates[panelId] ?? .unknown) == .unknown)

        appDelegate.recordReportedShellActivity(
            workspaceId: workspace.id,
            surfaceId: panelId,
            state: .promptIdle
        )

        // Unreachable at report time → buffered, not dropped, not yet applied.
        #expect(
            (workspace.panelShellActivityStates[panelId] ?? .unknown) == .unknown,
            "Report must not apply while the workspace is unreachable"
        )
        #expect(
            appDelegate.hasPendingShellActivityReports,
            "An unreachable report must be buffered, not dropped"
        )

        // A later tab-set change (a workspace registering) replays the buffer onto
        // the now-live panel.
        _ = manager.addTab(select: false)

        #expect(
            workspace.panelShellActivityStates[panelId] == .promptIdle,
            "Buffered shell state must replay onto the live panel once it registers"
        )
        #expect(
            !appDelegate.hasPendingShellActivityReports,
            "Replayed reports must be cleared from the buffer"
        )
    }

    // The restore race also has a window where reports land after the restored
    // `tabs` were assigned but before the window registers with AppDelegate. No
    // tabs change follows, so manager registration must itself replay the buffer.
    @Test func bufferedReportReplaysOnManagerRegistration() throws {
        let appDelegate = try #require(AppDelegate.shared, "Test host AppDelegate expected")
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        defer { appDelegate.discardPendingShellActivity(forWorkspaceId: workspace.id) }

        #expect(appDelegate.tabManagerFor(tabId: workspace.id) == nil)
        appDelegate.recordReportedShellActivity(workspaceId: workspace.id, surfaceId: panelId, state: .promptIdle)
        #expect(appDelegate.hasPendingShellActivityReports)

        // No tabs change — registration is the only replay trigger here.
        manager.flushPendingShellActivityForRegisteredWorkspaces()

        #expect(
            workspace.panelShellActivityStates[panelId] == .promptIdle,
            "Manager registration must replay reports buffered before it became reachable"
        )
        #expect(!appDelegate.hasPendingShellActivityReports)
    }

    // A buffered report for a surface that does not exist when the workspace
    // registers (stale/post-close telemetry) must be discarded, not retained
    // forever — otherwise a single workspace's bucket grows unbounded.
    @Test func staleBufferedReportsAreDiscardedOnRegistration() throws {
        let appDelegate = try #require(AppDelegate.shared, "Test host AppDelegate expected")
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let bogusSurfaceId = UUID()
        defer { appDelegate.discardPendingShellActivity(forWorkspaceId: workspace.id) }

        #expect(appDelegate.tabManagerFor(tabId: workspace.id) == nil)

        // One real surface and one that will never exist, both buffered while the
        // workspace is unreachable.
        appDelegate.recordReportedShellActivity(workspaceId: workspace.id, surfaceId: panelId, state: .promptIdle)
        appDelegate.recordReportedShellActivity(workspaceId: workspace.id, surfaceId: bogusSurfaceId, state: .promptIdle)
        #expect(appDelegate.hasPendingShellActivityReports)

        _ = manager.addTab(select: false)

        #expect(
            workspace.panelShellActivityStates[panelId] == .promptIdle,
            "The real surface's buffered report must still apply"
        )
        #expect(
            !appDelegate.hasPendingShellActivityReports,
            "The stale surface's report must be discarded on registration, not retained"
        )
    }
}
