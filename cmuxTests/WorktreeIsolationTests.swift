import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Mock GitCommandRunner

/// Test double that records calls and returns configurable results.
final class MockGitCommandRunner: GitCommandRunner {
    var isGitRepoResult = true
    var createWorktreeResult = true
    var removeWorktreeCalls: [(repoPath: String, worktreePath: String)] = []
    var createWorktreeCalls: [(repoPath: String, worktreePath: String, branch: String)] = []

    func isGitRepository(at path: String) -> Bool {
        isGitRepoResult
    }

    func createWorktree(repoPath: String, worktreePath: String, branch: String) -> Bool {
        createWorktreeCalls.append((repoPath, worktreePath, branch))
        return createWorktreeResult
    }

    func removeWorktree(repoPath: String, worktreePath: String) {
        removeWorktreeCalls.append((repoPath, worktreePath))
    }
}

// MARK: - shouldUseWorktree Tests

final class WorktreeIsolationShouldUseTests: XCTestCase {

    func testPerTaskTrueOverridesGlobalFalse() {
        let task = ScheduledTask(
            name: "test", cronExpression: "* * * * *", command: "echo",
            useWorktree: true
        )
        XCTAssertTrue(WorktreeIsolation.shouldUseWorktree(task: task, globalEnabled: false))
    }

    func testPerTaskFalseOverridesGlobalTrue() {
        let task = ScheduledTask(
            name: "test", cronExpression: "* * * * *", command: "echo",
            useWorktree: false
        )
        XCTAssertFalse(WorktreeIsolation.shouldUseWorktree(task: task, globalEnabled: true))
    }

    func testPerTaskNilDefersToGlobalTrue() {
        let task = ScheduledTask(
            name: "test", cronExpression: "* * * * *", command: "echo",
            useWorktree: nil
        )
        XCTAssertTrue(WorktreeIsolation.shouldUseWorktree(task: task, globalEnabled: true))
    }

    func testPerTaskNilDefersToGlobalFalse() {
        let task = ScheduledTask(
            name: "test", cronExpression: "* * * * *", command: "echo",
            useWorktree: nil
        )
        XCTAssertFalse(WorktreeIsolation.shouldUseWorktree(task: task, globalEnabled: false))
    }
}

// MARK: - resolveWorkingDirectory Tests

final class WorktreeIsolationResolveTests: XCTestCase {

    // MARK: - worktree OFF runs in configured workingDirectory

    func testWorktreeOffUsesOriginalDirectory() {
        let mockGit = MockGitCommandRunner()
        let task = ScheduledTask(
            name: "test", cronExpression: "* * * * *", command: "echo",
            workingDirectory: "/Users/dev/project",
            useWorktree: nil
        )

        let result = WorktreeIsolation.resolveWorkingDirectory(
            task: task,
            runId: UUID(),
            globalEnabled: false,
            gitRunner: mockGit
        )

        XCTAssertEqual(result.effectiveDirectory, "/Users/dev/project")
        XCTAssertNil(result.worktreePath)
        XCTAssertTrue(mockGit.createWorktreeCalls.isEmpty, "Should not attempt worktree creation")
    }

    func testWorktreeOffWithNoWorkingDirectoryReturnsNil() {
        let mockGit = MockGitCommandRunner()
        let task = ScheduledTask(
            name: "test", cronExpression: "* * * * *", command: "echo",
            workingDirectory: nil,
            useWorktree: nil
        )

        let result = WorktreeIsolation.resolveWorkingDirectory(
            task: task,
            runId: UUID(),
            globalEnabled: false,
            gitRunner: mockGit
        )

        XCTAssertNil(result.effectiveDirectory)
        XCTAssertNil(result.worktreePath)
    }

    func testWorktreeOffExplicitPerTaskFalseUsesOriginalDirectory() {
        let mockGit = MockGitCommandRunner()
        let task = ScheduledTask(
            name: "test", cronExpression: "* * * * *", command: "echo",
            workingDirectory: "/Users/dev/project",
            useWorktree: false
        )

        // Even with global enabled, per-task false should skip worktree
        let result = WorktreeIsolation.resolveWorkingDirectory(
            task: task,
            runId: UUID(),
            globalEnabled: true,
            gitRunner: mockGit
        )

        XCTAssertEqual(result.effectiveDirectory, "/Users/dev/project")
        XCTAssertNil(result.worktreePath)
        XCTAssertTrue(mockGit.createWorktreeCalls.isEmpty)
    }

    // MARK: - worktree ON sets cwd to worktree path

    func testWorktreeOnCreatesWorktreeAndSetsPath() {
        let mockGit = MockGitCommandRunner()
        mockGit.isGitRepoResult = true
        mockGit.createWorktreeResult = true

        let task = ScheduledTask(
            name: "test", cronExpression: "* * * * *", command: "echo",
            workingDirectory: "/Users/dev/project",
            useWorktree: nil
        )
        let runId = UUID()

        let result = WorktreeIsolation.resolveWorkingDirectory(
            task: task,
            runId: runId,
            globalEnabled: true,
            gitRunner: mockGit
        )

        // Should have a worktree path under .git/crux-worktrees/
        XCTAssertNotNil(result.worktreePath)
        XCTAssertTrue(result.worktreePath!.contains(".git/crux-worktrees/scheduler-"))
        XCTAssertEqual(result.effectiveDirectory, result.worktreePath)

        // Verify git commands were called
        XCTAssertEqual(mockGit.createWorktreeCalls.count, 1)
        XCTAssertEqual(mockGit.createWorktreeCalls[0].repoPath, "/Users/dev/project")
        XCTAssertTrue(mockGit.createWorktreeCalls[0].branch.hasPrefix("crux/scheduler/"))
    }

    func testWorktreeOnNonGitRepoFallsBackToOriginal() {
        let mockGit = MockGitCommandRunner()
        mockGit.isGitRepoResult = false

        let task = ScheduledTask(
            name: "test", cronExpression: "* * * * *", command: "echo",
            workingDirectory: "/Users/dev/not-a-repo",
            useWorktree: nil
        )

        let result = WorktreeIsolation.resolveWorkingDirectory(
            task: task,
            runId: UUID(),
            globalEnabled: true,
            gitRunner: mockGit
        )

        XCTAssertEqual(result.effectiveDirectory, "/Users/dev/not-a-repo")
        XCTAssertNil(result.worktreePath)
        XCTAssertTrue(mockGit.createWorktreeCalls.isEmpty)
    }

    func testWorktreeOnCreationFailsFallsBackToOriginal() {
        let mockGit = MockGitCommandRunner()
        mockGit.isGitRepoResult = true
        mockGit.createWorktreeResult = false

        let task = ScheduledTask(
            name: "test", cronExpression: "* * * * *", command: "echo",
            workingDirectory: "/Users/dev/project",
            useWorktree: nil
        )

        let result = WorktreeIsolation.resolveWorkingDirectory(
            task: task,
            runId: UUID(),
            globalEnabled: true,
            gitRunner: mockGit
        )

        XCTAssertEqual(result.effectiveDirectory, "/Users/dev/project")
        XCTAssertNil(result.worktreePath)
        XCTAssertEqual(mockGit.createWorktreeCalls.count, 1) // Attempted but failed
    }

    func testWorktreeOnNoWorkingDirectorySkipsWorktree() {
        let mockGit = MockGitCommandRunner()
        let task = ScheduledTask(
            name: "test", cronExpression: "* * * * *", command: "echo",
            workingDirectory: nil,
            useWorktree: true
        )

        let result = WorktreeIsolation.resolveWorkingDirectory(
            task: task,
            runId: UUID(),
            globalEnabled: true,
            gitRunner: mockGit
        )

        // No working directory means no worktree to create
        XCTAssertNil(result.effectiveDirectory)
        XCTAssertNil(result.worktreePath)
    }

    // MARK: - per-task useWorktree overrides global setting

    func testPerTaskTrueOverridesGlobalFalseCreatesWorktree() {
        let mockGit = MockGitCommandRunner()
        mockGit.isGitRepoResult = true
        mockGit.createWorktreeResult = true

        let task = ScheduledTask(
            name: "test", cronExpression: "* * * * *", command: "echo",
            workingDirectory: "/Users/dev/project",
            useWorktree: true  // Override: ON
        )

        let result = WorktreeIsolation.resolveWorkingDirectory(
            task: task,
            runId: UUID(),
            globalEnabled: false,  // Global: OFF
            gitRunner: mockGit
        )

        XCTAssertNotNil(result.worktreePath, "Per-task true should create worktree even when global is off")
        XCTAssertEqual(result.effectiveDirectory, result.worktreePath)
    }

    func testPerTaskFalseOverridesGlobalTrueSkipsWorktree() {
        let mockGit = MockGitCommandRunner()

        let task = ScheduledTask(
            name: "test", cronExpression: "* * * * *", command: "echo",
            workingDirectory: "/Users/dev/project",
            useWorktree: false  // Override: OFF
        )

        let result = WorktreeIsolation.resolveWorkingDirectory(
            task: task,
            runId: UUID(),
            globalEnabled: true,  // Global: ON
            gitRunner: mockGit
        )

        XCTAssertNil(result.worktreePath, "Per-task false should skip worktree even when global is on")
        XCTAssertEqual(result.effectiveDirectory, "/Users/dev/project")
        XCTAssertTrue(mockGit.createWorktreeCalls.isEmpty)
    }
}

// MARK: - Cleanup Tests

final class WorktreeIsolationCleanupTests: XCTestCase {

    func testCleanupWorktreeCallsGitRunner() {
        let mockGit = MockGitCommandRunner()
        WorktreeIsolation.cleanupWorktree(
            repoPath: "/Users/dev/project",
            worktreePath: "/Users/dev/project/.git/crux-worktrees/scheduler-abc12345",
            gitRunner: mockGit
        )

        XCTAssertEqual(mockGit.removeWorktreeCalls.count, 1)
        XCTAssertEqual(mockGit.removeWorktreeCalls[0].repoPath, "/Users/dev/project")
        XCTAssertEqual(mockGit.removeWorktreeCalls[0].worktreePath,
                       "/Users/dev/project/.git/crux-worktrees/scheduler-abc12345")
    }
}

// MARK: - SchedulerSettings Tests

final class SchedulerSettingsTests: XCTestCase {

    func testWorktreeIsolationKeyValue() {
        XCTAssertEqual(SchedulerSettings.worktreeIsolationKey, "schedulerWorktreeIsolation")
    }

    func testWorktreeIsolationDefaultIsFalse() {
        // UserDefaults.standard.bool(forKey:) returns false for unset keys
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SchedulerSettings.worktreeIsolationKey)
        XCTAssertFalse(SchedulerSettings.isWorktreeIsolationEnabled)
    }
}
