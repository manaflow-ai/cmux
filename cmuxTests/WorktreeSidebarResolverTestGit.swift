import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Controllable Git seam for resolver coalescing tests.
actor WorktreeSidebarResolverTestGit: WorktreeSidebarGitOperating {
    private let projectRootPath: String
    private var firstListContinuation: CheckedContinuation<[WorktreeSidebarWorktree], Never>?
    private var firstListWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var listRequestCount = 0

    init(projectRootPath: String) {
        self.projectRootPath = projectRootPath
    }

    func listWorktrees(projectRootPath: String) async throws -> [WorktreeSidebarWorktree] {
        listRequestCount += 1
        guard listRequestCount == 1 else { return [worktree] }
        return await withCheckedContinuation { continuation in
            firstListContinuation = continuation
            let waiters = firstListWaiters
            firstListWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitForFirstListRequest() async {
        guard firstListContinuation == nil else { return }
        await withCheckedContinuation { firstListWaiters.append($0) }
    }

    func resolveFirstListRequest() {
        firstListContinuation?.resume(returning: [worktree])
        firstListContinuation = nil
    }

    func isDirty(projectRootPath: String, worktreePath: String) async throws -> Bool { false }

    func inspectDeletion(
        projectRootPath: String,
        worktreePath: String
    ) async throws -> WorktreeSidebarDeletionInspection {
        throw WorktreeSidebarGitError.worktreeNotFound
    }

    func removeWorktree(
        projectRootPath: String,
        expected: WorktreeSidebarDeletionInspection,
        force: Bool
    ) async throws -> WorktreeSidebarDeletionResult {
        throw WorktreeSidebarGitError.worktreeNotFound
    }

    func createWorktree(
        projectRootPath: String,
        userInput: String
    ) async throws -> WorktreeSidebarCreationResult {
        throw WorktreeSidebarGitError.invalidBranchName(userInput)
    }

    func listingWatchPaths(projectRootPath: String) async -> [String] { [] }

    func statusWatchPlan(
        worktreePath: String,
        excludingWorktreePaths: [String]
    ) async -> WorktreeSidebarStatusWatchPlan { .empty }

    private var worktree: WorktreeSidebarWorktree {
        WorktreeSidebarWorktree(
            path: projectRootPath,
            head: nil,
            branchRef: "refs/heads/main",
            isDetached: false,
            isBare: false,
            isMain: true,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil
        )
    }
}
