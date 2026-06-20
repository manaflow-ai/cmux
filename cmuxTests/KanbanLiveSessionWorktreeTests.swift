import CmuxKanbanCore
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Regression coverage for live-session run-directory resolution.
///
/// The Kanban "Live" button opened nothing when the hosting workspace was not a
/// git repository (e.g. the user's home directory): ``GitWorktreeProvisioner``
/// cannot create a worktree there and returns nil, and
/// ``KanbanWebRendererCoordinator`` used to treat that as a hard failure — a
/// silent `opened: false`, so the card never moved and no session opened —
/// instead of running the agent directly in the workspace directory the way the
/// headless ``CmuxNativeBackend`` already does. These exercise the pure
/// resolution helper that decision now flows through.
struct KanbanLiveSessionWorktreeTests {
    @Test
    func usesTheCardsExistingWorktreeWhenItHasOne() {
        let resolved = KanbanWebRendererCoordinator.resolveLiveSessionWorktree(
            existingWorktreePath: "/wt/card",
            existingBranchName: "cmux/kanban/abc",
            provisionedWorktreePath: nil,
            provisionedBranchName: nil,
            workspaceDirectory: "/Users/me"
        )
        #expect(resolved == .init(worktreePath: "/wt/card", branchName: "cmux/kanban/abc"))
    }

    @Test
    func usesAFreshlyProvisionedWorktreeWhenThereIsNoExistingOne() {
        let resolved = KanbanWebRendererCoordinator.resolveLiveSessionWorktree(
            existingWorktreePath: nil,
            existingBranchName: nil,
            provisionedWorktreePath: "/wt/new",
            provisionedBranchName: "cmux/kanban/def",
            workspaceDirectory: "/Users/me"
        )
        #expect(resolved == .init(worktreePath: "/wt/new", branchName: "cmux/kanban/def"))
    }

    /// The regression: a non-git workspace cannot provision a worktree, so the
    /// live session must fall back to running in the workspace directory (with no
    /// isolated branch) rather than refusing to open. Before the fix this
    /// returned nil and ``openAgentSession`` reported a silent `opened: false`.
    @Test
    func fallsBackToTheWorkspaceDirectoryWhenProvisioningFails() {
        let resolved = KanbanWebRendererCoordinator.resolveLiveSessionWorktree(
            existingWorktreePath: nil,
            existingBranchName: nil,
            provisionedWorktreePath: nil,
            provisionedBranchName: nil,
            workspaceDirectory: "/Users/me/not-a-repo"
        )
        #expect(resolved == .init(worktreePath: "/Users/me/not-a-repo", branchName: nil))
    }

    @Test
    func returnsNilOnlyWhenThereIsNoDirectoryAtAll() {
        let resolved = KanbanWebRendererCoordinator.resolveLiveSessionWorktree(
            existingWorktreePath: nil,
            existingBranchName: nil,
            provisionedWorktreePath: nil,
            provisionedBranchName: nil,
            workspaceDirectory: nil
        )
        #expect(resolved == nil)
    }

    /// Empty strings count as "absent" at every tier, so an empty existing
    /// worktree still falls through to the workspace directory.
    @Test
    func treatsEmptyPathsAsAbsent() {
        let resolved = KanbanWebRendererCoordinator.resolveLiveSessionWorktree(
            existingWorktreePath: "",
            existingBranchName: nil,
            provisionedWorktreePath: "",
            provisionedBranchName: nil,
            workspaceDirectory: "/Users/me"
        )
        #expect(resolved == .init(worktreePath: "/Users/me", branchName: nil))
    }
}
