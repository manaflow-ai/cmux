import Foundation
import Testing
import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceContextTests {
    @Test func assignedContextSurvivesShellReportsAndFocusChanges() throws {
        try withWorkspace { workspace, apply in
            let first = try #require(workspace.focusedPanelId)
            workspace.updatePanelDirectory(panelId: first, directory: "/tmp/hq")
            try requireOK(apply(["workspace_directory": "/tmp/task", "pr_number": 123, "pr_url": "https://github.com/acme/project/pull/123"]))
            workspace.updatePanelDirectory(panelId: first, directory: "/tmp/another-hq")
            workspace.updatePanelGitBranch(panelId: first, branch: "hq-main", isDirty: false)
            workspace.updatePanelPullRequest(panelId: first, number: 987, label: "PR", url: URL(string: "https://github.com/acme/hq/pull/987")!, status: .open)
            let pane = try #require(workspace.paneId(forPanelId: first))
            let second = try #require(workspace.newTerminalSurface(inPane: pane, focus: false))
            workspace.focusPanel(second.id)
            workspace.focusPanel(first)
            #expect(workspace.reportedPanelDirectory(panelId: first) == "/tmp/another-hq")
            #expect(workspace.currentDirectory == "/tmp/another-hq")
            #expect(workspace.resolvedWorkingDirectory() == "/tmp/task")
            #expect(workspace.sidebarDirectoriesInDisplayOrder() == ["/tmp/task"])
            #expect(workspace.sidebarFinderDirectory() == "/tmp/task")
            #expect(workspace.customSidebarWorkspaceSnapshot(index: 0, selectedId: workspace.id, unreadCount: 0).directory == "/tmp/task")
            #expect(workspace.sidebarPullRequestsInDisplayOrder().map(\.number) == [123])
            #expect(workspace.sidebarGitBranchesInDisplayOrder().isEmpty)
            workspace.clearSidebarGitMetadata()
            #expect(workspace.sidebarPullRequestsInDisplayOrder().map(\.number) == [123])
        }
    }

    @Test func newTerminalsUseAssignedDirectoryButExplicitDirectoryWins() throws {
        try withWorkspace { workspace, apply in
            let first = try #require(workspace.focusedPanelId)
            let original = try #require(workspace.terminalPanel(for: first))
            let initialDirectory = original.requestedWorkingDirectory
            workspace.updatePanelDirectory(panelId: first, directory: "/tmp/hq")
            try requireOK(apply(["workspace_directory": "/tmp/task"]))
            let pane = try #require(workspace.paneId(forPanelId: first))
            let tab = try #require(workspace.newTerminalSurface(inPane: pane, focus: false, inheritWorkingDirectoryFallback: true))
            let split = try #require(workspace.newTerminalSplit(from: first, orientation: .horizontal, focus: false))
            let explicit = try #require(workspace.newTerminalSurface(inPane: pane, focus: false, workingDirectory: "/tmp/explicit", inheritWorkingDirectoryFallback: true))
            #expect(tab.requestedWorkingDirectory == "/tmp/task")
            #expect(split.requestedWorkingDirectory == "/tmp/task")
            #expect(explicit.requestedWorkingDirectory == "/tmp/explicit")
            #expect(original.requestedWorkingDirectory == initialDirectory)
            #expect(workspace.reportedPanelDirectory(panelId: first) == "/tmp/hq")
        }
    }

    @Test func contextRoundTripsWithoutRetargetingRestoredTerminals() throws {
        try withWorkspace { workspace, apply in
            let first = try #require(workspace.focusedPanelId)
            workspace.updatePanelDirectory(panelId: first, directory: "/tmp/hq")
            try requireOK(apply(["workspace_directory": "/tmp/task", "pr_number": 123, "pr_url": "https://github.com/acme/project/pull/123", "pr_state": "merged"]))
            let snapshot = workspace.sessionSnapshot(includeScrollback: false)
            let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
            let restored = Workspace()
            defer { restored.teardownAllPanels() }
            restored.restoreSessionSnapshot(decoded)
            #expect(restored.sidebarDirectoriesInDisplayOrder() == ["/tmp/task"])
            #expect(restored.sidebarPullRequestsInDisplayOrder().first?.status == .merged)
            #expect(restored.focusedPanelId.flatMap { restored.reportedPanelDirectory(panelId: $0) } == "/tmp/hq")
        }
    }

    @Test func invalidCombinedUpdateIsAtomicAndClearingRestoresAutomaticContext() throws {
        try withWorkspace { workspace, apply in
            let panel = try #require(workspace.focusedPanelId)
            workspace.updatePanelDirectory(panelId: panel, directory: "/tmp/hq")
            workspace.updatePanelPullRequest(panelId: panel, number: 10, label: "PR", url: URL(string: "https://github.com/acme/hq/pull/10")!, status: .open)
            let failed = apply(["workspace_directory": "/tmp/incorrect", "pr_number": 123, "pr_url": "file:///tmp/bad"])
            guard case .err = failed else { Issue.record("Expected rejection"); return }
            #expect(workspace.sidebarDirectoriesInDisplayOrder() == ["/tmp/hq"])
            try requireOK(apply(["workspace_directory": "/tmp/task", "pr_number": 123, "pr_url": "https://github.com/acme/project/pull/123"]))
            try requireOK(apply(["clear_directory": true, "clear_pull_request": true]))
            #expect(workspace.sidebarDirectoriesInDisplayOrder() == ["/tmp/hq"])
            #expect(workspace.sidebarPullRequestsInDisplayOrder().map(\.number) == [10])
        }
    }

    private func requireOK(_ result: TerminalController.V2CallResult) throws {
        if case .err(_, let message, _) = result { throw ContextFailure(message: message) }
    }

    private func withWorkspace(_ body: (Workspace, ([String: Any]) -> TerminalController.V2CallResult) throws -> Void) throws {
        let controller = TerminalController.shared
        let previous = controller.activeTabManagerForCallerNotification()
        let manager = TabManager()
        controller.setActiveTabManager(manager)
        defer {
            controller.setActiveTabManager(previous)
            for workspace in manager.tabs { workspace.teardownAllPanels() }
        }
        let workspace = try #require(manager.selectedWorkspace)
        try body(workspace) { fields in
            var params = fields
            params["workspace_id"] = workspace.id.uuidString
            params["action"] = "set_context"
            return controller.v2WorkspaceAction(params: params)
        }
    }

    private struct ContextFailure: Error { let message: String }
}
