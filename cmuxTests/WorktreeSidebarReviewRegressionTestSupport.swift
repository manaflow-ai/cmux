import Foundation
import Observation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Controllable dependencies for worktree-sidebar review regressions.
actor WorktreeSidebarReviewRegressionGit: WorktreeSidebarGitOperating {
    let worktree: WorktreeSidebarWorktree
    private let returnsReplacementOnFourthListing: Bool
    private var listingCallCount = 0
    private var blockedListingCalls: Set<Int> = [2, 3, 4]
    private var listingContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var listingCallWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(
        projectRootPath: String,
        worktreePath: String,
        returnsReplacementOnFourthListing: Bool = false
    ) {
        self.returnsReplacementOnFourthListing = returnsReplacementOnFourthListing
        worktree = WorktreeSidebarWorktree(
            path: worktreePath,
            head: "1111111111111111111111111111111111111111",
            branchRef: "refs/heads/review-regression",
            isDetached: false,
            isBare: false,
            isMain: false,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil
        )
    }

    func listWorktrees(projectRootPath: String) async throws -> [WorktreeSidebarWorktree] {
        listingCallCount += 1
        let call = listingCallCount
        let readyWaiterKeys = listingCallWaiters.keys.filter { $0 <= call }
        for key in readyWaiterKeys {
            listingCallWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
        }
        if blockedListingCalls.contains(call) {
            await withCheckedContinuation { continuation in
                listingContinuations[call] = continuation
            }
        }
        return call < 4 || returnsReplacementOnFourthListing ? [worktree] : []
    }

    func waitUntilListingCall(_ call: Int) async {
        guard listingCallCount < call else { return }
        await withCheckedContinuation { continuation in
            listingCallWaiters[call, default: []].append(continuation)
        }
    }

    func resumeListingCall(_ call: Int) {
        blockedListingCalls.remove(call)
        listingContinuations.removeValue(forKey: call)?.resume()
    }

    func isDirty(projectRootPath: String, worktreePath: String) async throws -> Bool { false }

    func inspectDeletion(
        projectRootPath: String,
        worktreePath: String
    ) async throws -> WorktreeSidebarDeletionInspection {
        WorktreeSidebarDeletionInspection(
            worktree: worktree,
            statusFingerprint: .empty,
            ignoredFingerprint: .empty,
            hasUncommittedChanges: false,
            hasIgnoredFiles: false,
            unpushedCommitCount: 0,
            branchDisposition: .noLocalBranch,
            hasInitializedSubmodules: false
        )
    }

    func removeWorktree(
        projectRootPath: String,
        expected: WorktreeSidebarDeletionInspection,
        force: Bool
    ) async throws -> WorktreeSidebarDeletionResult {
        WorktreeSidebarDeletionResult(removal: .removed, branch: .notApplicable)
    }

    func createWorktree(
        projectRootPath: String,
        userInput: String
    ) async throws -> WorktreeSidebarCreationResult {
        throw WorktreeSidebarGitError.invalidBranchName(userInput)
    }

    func listingWatchPlan(projectRootPath: String) async -> WorktreeSidebarListingWatchPlan { .empty }

    func statusWatchPlan(
        worktreePath: String,
        excludingWorktreePaths: [String]
    ) async -> WorktreeSidebarStatusWatchPlan { .empty }
}

@MainActor
struct WorktreeSidebarReviewRegressionDialogs: WorktreeSidebarDialogPresenting {
    func promptForBranchName(projectName: String) -> String? { nil }
    func confirmDeletion(
        _ inspection: WorktreeSidebarDeletionInspection,
        force: Bool
    ) -> Bool { true }
    func presentError(_ error: Error) {}
    func presentPreservedBranch(name: String, reason: String) {}
}

/// Waits on Observation notifications rather than polling model state.
@MainActor
final class WorktreeSidebarModelWaiter {
    func wait(
        for model: WorktreeSidebarModel,
        until condition: @escaping @MainActor (WorktreeSidebarModel) -> Bool
    ) async {
        guard !condition(model) else { return }
        await withCheckedContinuation { continuation in
            observe(model: model, condition: condition, continuation: continuation)
        }
    }

    private func observe(
        model: WorktreeSidebarModel,
        condition: @escaping @MainActor (WorktreeSidebarModel) -> Bool,
        continuation: CheckedContinuation<Void, Never>
    ) {
        guard !condition(model) else {
            continuation.resume()
            return
        }
        withObservationTracking {
            _ = condition(model)
        } onChange: {
            Task { @MainActor [self] in
                observe(model: model, condition: condition, continuation: continuation)
            }
        }
    }
}
