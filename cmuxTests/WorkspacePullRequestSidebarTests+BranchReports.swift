import XCTest
import Darwin
import CmuxProcess

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Branch-only git report dirty state
extension WorkspacePullRequestSidebarTests {
    func testBranchOnlyGitReportDoesNotClearExistingDirtyState() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceGitBranch(
            tabId: workspace.id,
            surfaceId: panelId,
            branch: "main",
            isDirty: true
        )
        manager.updateSurfaceGitBranch(
            tabId: workspace.id,
            surfaceId: panelId,
            branch: "main",
            isDirty: nil
        )

        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, "main")
        XCTAssertEqual(
            workspace.panelGitBranches[panelId]?.isDirty,
            true,
            "Branch-only shell reports must not clear dirty state computed by the sidebar watcher."
        )
    }

    func testBranchOnlyGitReportClearsDirtyStateWhenBranchChanges() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceGitBranch(
            tabId: workspace.id,
            surfaceId: panelId,
            branch: "feature/old",
            isDirty: true
        )
        manager.updateSurfaceGitBranch(
            tabId: workspace.id,
            surfaceId: panelId,
            branch: "feature/new",
            isDirty: nil
        )

        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, "feature/new")
        XCTAssertEqual(
            workspace.panelGitBranches[panelId]?.isDirty,
            false,
            "Branch-only shell reports for a new branch must not reuse the previous branch's dirty state."
        )
    }

    func testTabScopedGitBranchUnknownStatusClearsDirtyWhenBranchChanges() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        workspace.gitBranch = SidebarGitBranchState(branch: "main", isDirty: true)

        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
        }

        let response = TerminalController.shared.handleSocketLine(
            "report_git_branch feature/new --status=unknown --tab=\(workspace.id.uuidString)"
        )

        XCTAssertEqual(response, "OK")
        XCTAssertEqual(workspace.gitBranch?.branch, "feature/new")
        XCTAssertEqual(
            workspace.gitBranch?.isDirty,
            false,
            "Tab-scoped branch-only reports for a new branch must not reuse the previous branch's dirty state."
        )
    }

}
