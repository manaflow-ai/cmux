import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5032.
///
/// The Project Worktrees sidebar `+` button created the worktree on disk but
/// the workspace tab exited immediately, because the worktree setup command was
/// passed as the workspace's primary process (`initialTerminalCommand`). A
/// workspace closes the moment its main process exits, so the setup command
/// finishing (or failing) killed the tab. The fix routes setup through
/// `initialTerminalInput` so the workspace's main process stays the login shell.
@Suite("Extension worktree workspace spawn args")
struct ExtensionWorktreeSpawnArgsTests {
    private func makeResult(setupCommand: String) -> CmuxExtensionWorktreeCreationResult {
        CmuxExtensionWorktreeCreationResult(
            worktreePath: "/tmp/project/.cmux/worktrees/cmux-sidebar-123",
            workspaceTitle: "cmux-sidebar-123",
            setupCommand: setupCommand
        )
    }

    @Test("setup command runs as interactive shell input")
    func setupCommandRunsAsShellInput() {
        let setup = "cd '/tmp/sample' && python3 -m http.server 4100"
        let args = makeResult(setupCommand: setup).workspaceSpawnArgs()

        // The setup command must NOT become the workspace's primary process (a
        // one-shot command there makes the tab die the moment it exits). It is
        // delivered as input (with a trailing newline so it executes) into the
        // interactive shell, matching the `cmux new-workspace --cwd` contract.
        // The spawn-args type has no primary-command field, so the original bug
        // is structurally unrepresentable here.
        #expect(args.initialTerminalInput == setup + "\n")
    }

    @Test("worktree path is the workspace working directory")
    func worktreePathIsWorkingDirectory() {
        let args = makeResult(setupCommand: "echo hi").workspaceSpawnArgs()

        #expect(args.workingDirectory == "/tmp/project/.cmux/worktrees/cmux-sidebar-123")
        #expect(args.inheritWorkingDirectory == false)
        #expect(args.title == "cmux-sidebar-123")
    }

    @Test("empty setup command yields no input")
    func emptySetupCommandYieldsNoInput() {
        let args = makeResult(setupCommand: "").workspaceSpawnArgs()

        #expect(args.initialTerminalInput == nil)
    }
}

/// Coverage for https://github.com/manaflow-ai/cmux/issues/6510 — worktree
/// management (delete + "open terminal inside") for the Project Worktrees
/// sidebar. Pure decision/parse helpers are tested in isolation; the on-disk
/// removal path is exercised end-to-end against a real temporary git repo.
@Suite("Extension worktree management")
struct ExtensionWorktreeManagementTests {
    // MARK: - Open terminal inside (issue #5032 lesson)

    @Test("open-terminal args spawn an interactive shell, not a one-shot command")
    func openTerminalArgsKeepShellAlive() {
        let path = "/tmp/project/.cmux/worktrees/cmux-sidebar-123"
        let args = CmuxExtensionWorktreePrototype.openTerminalArgs(worktreePath: path)

        // The type has no primary-command field, so "Open terminal inside"
        // cannot make a one-shot command the workspace's main process — the tab
        // therefore can't die the instant a command exits (issue #5032).
        #expect(args.workingDirectory == path)
        #expect(args.inheritWorkingDirectory == false)
        #expect(args.title == "cmux-sidebar-123")
    }

    @Test("open-terminal args standardize the working directory and title")
    func openTerminalArgsStandardizePath() {
        let args = CmuxExtensionWorktreePrototype.openTerminalArgs(
            worktreePath: "/tmp/project/.cmux/worktrees/wt/"
        )
        #expect(args.workingDirectory == "/tmp/project/.cmux/worktrees/wt")
        #expect(args.title == "wt")
    }

    // MARK: - Managed worktree identity parsing

    @Test("managed worktree identity is parsed from a .cmux/worktrees path")
    func managedWorktreeIdentityParsesManagedPath() {
        let identity = CmuxExtensionWorktreePrototype.managedWorktreeIdentity(
            gitRootPath: "/Users/me/repo/.cmux/worktrees/cmux-sidebar-9"
        )
        #expect(identity?.parentRepoPath == "/Users/me/repo")
        #expect(identity?.worktreePath == "/Users/me/repo/.cmux/worktrees/cmux-sidebar-9")
    }

    @Test("non-worktree git roots are not treated as managed worktrees")
    func managedWorktreeIdentityRejectsPlainCheckouts() {
        #expect(CmuxExtensionWorktreePrototype.managedWorktreeIdentity(gitRootPath: "/Users/me/repo") == nil)
        #expect(CmuxExtensionWorktreePrototype.managedWorktreeIdentity(gitRootPath: nil) == nil)
        #expect(CmuxExtensionWorktreePrototype.managedWorktreeIdentity(gitRootPath: "") == nil)
        // Trailing container with no worktree name is not a worktree.
        #expect(CmuxExtensionWorktreePrototype.managedWorktreeIdentity(
            gitRootPath: "/Users/me/repo/.cmux/worktrees/"
        ) == nil)
    }

    // MARK: - Removal confirmation / force decisions

    @Test("clean removals respect the suppression flag")
    func cleanRemovalRespectsSuppression() {
        let clean = CmuxExtensionWorktreeRemovalSafety(
            hasUncommittedChanges: false,
            unpushedCommitCount: 0,
            branchName: "cmux-sidebar-1"
        )
        #expect(clean.isClean)
        #expect(clean.requiresForce == false)
        #expect(CmuxExtensionWorktreePrototype.removalRequiresConfirmation(safety: clean, suppressionEnabled: false))
        #expect(!CmuxExtensionWorktreePrototype.removalRequiresConfirmation(safety: clean, suppressionEnabled: true))
    }

    @Test("dirty or unpushed removals always confirm, ignoring suppression")
    func unsafeRemovalAlwaysConfirms() {
        let dirty = CmuxExtensionWorktreeRemovalSafety(
            hasUncommittedChanges: true,
            unpushedCommitCount: 0,
            branchName: nil
        )
        #expect(dirty.requiresForce)
        // Suppression must never bypass a data-loss prompt.
        #expect(CmuxExtensionWorktreePrototype.removalRequiresConfirmation(safety: dirty, suppressionEnabled: true))

        let unpushed = CmuxExtensionWorktreeRemovalSafety(
            hasUncommittedChanges: false,
            unpushedCommitCount: 2,
            branchName: nil
        )
        #expect(unpushed.hasUnpushedCommits)
        #expect(unpushed.requiresForce == false)
        #expect(CmuxExtensionWorktreePrototype.removalRequiresConfirmation(safety: unpushed, suppressionEnabled: true))
    }

    // MARK: - Which tabs close on removal

    @Test("only workspaces rooted in the removed worktree are selected to close")
    func workspaceSelectionMatchesWorktreeRoot() {
        let worktree = "/Users/me/repo/.cmux/worktrees/wt-a"
        let inWorktree1 = UUID()
        let inWorktree2 = UUID()
        let elsewhere = UUID()
        let workspaces: [(id: UUID, gitRootPath: String?)] = [
            (id: inWorktree1, gitRootPath: worktree),
            (id: elsewhere, gitRootPath: "/Users/me/repo"),
            (id: inWorktree2, gitRootPath: worktree + "/"),
            (id: UUID(), gitRootPath: nil),
        ]
        let ids = CmuxExtensionWorktreePrototype.workspaceIdsRooted(
            inWorktreePath: worktree,
            workspaces: workspaces
        )
        #expect(ids == [inWorktree1, inWorktree2])
    }

    // MARK: - On-disk removal (real git)

    @Test("removing a clean worktree deletes it from disk and from git")
    func removeCleanWorktreeRemovesFromDiskAndGit() async throws {
        let repo = try GitFixture.makeRepo()
        defer { GitFixture.cleanUp(repo) }

        try FileManager.default.createDirectory(
            atPath: repo + "/.cmux/worktrees",
            withIntermediateDirectories: true
        )
        let worktree = repo + "/.cmux/worktrees/clean-wt"
        GitFixture.run(["worktree", "add", "-b", "clean-wt", worktree, "HEAD"], in: repo)
        #expect(FileManager.default.fileExists(atPath: worktree))

        let safety = try await CmuxExtensionWorktreePrototype.inspectRemovalSafety(worktreePath: worktree)
        #expect(safety.isClean)

        try await CmuxExtensionWorktreePrototype.removeWorktree(worktreePath: worktree, force: false)

        #expect(!FileManager.default.fileExists(atPath: worktree))
        let list = GitFixture.run(["worktree", "list"], in: repo).out
        #expect(!list.contains("clean-wt"))
    }

    @Test("a dirty worktree is guarded: removal needs an explicit force")
    func dirtyWorktreeRequiresForce() async throws {
        let repo = try GitFixture.makeRepo()
        defer { GitFixture.cleanUp(repo) }

        try FileManager.default.createDirectory(
            atPath: repo + "/.cmux/worktrees",
            withIntermediateDirectories: true
        )
        let worktree = repo + "/.cmux/worktrees/dirty-wt"
        GitFixture.run(["worktree", "add", "-b", "dirty-wt", worktree, "HEAD"], in: repo)
        try "scratch\n".write(
            toFile: worktree + "/uncommitted.txt",
            atomically: true,
            encoding: .utf8
        )

        let safety = try await CmuxExtensionWorktreePrototype.inspectRemovalSafety(worktreePath: worktree)
        #expect(safety.hasUncommittedChanges)
        #expect(safety.requiresForce)

        // Without force, git refuses and the worktree survives.
        var refusedWithoutForce = false
        do {
            try await CmuxExtensionWorktreePrototype.removeWorktree(worktreePath: worktree, force: false)
        } catch {
            refusedWithoutForce = true
        }
        #expect(refusedWithoutForce)
        #expect(FileManager.default.fileExists(atPath: worktree))

        // With force (i.e. after the user confirmed the data-loss prompt) it goes.
        try await CmuxExtensionWorktreePrototype.removeWorktree(worktreePath: worktree, force: true)
        #expect(!FileManager.default.fileExists(atPath: worktree))
    }

    @Test("a sidebar-created worktree round-trips: create then remove")
    func createdWorktreeCanBeRemoved() async throws {
        let repo = try GitFixture.makeRepo()
        defer { GitFixture.cleanUp(repo) }

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(projectRootPath: repo)
        #expect(FileManager.default.fileExists(atPath: result.worktreePath))

        let identity = CmuxExtensionWorktreePrototype.managedWorktreeIdentity(gitRootPath: result.worktreePath)
        #expect(identity?.parentRepoPath == repo)

        // The created worktree carries untracked sample files, so removal needs
        // force — exactly the guarded path a user confirms through.
        try await CmuxExtensionWorktreePrototype.removeWorktree(worktreePath: result.worktreePath, force: true)
        #expect(!FileManager.default.fileExists(atPath: result.worktreePath))
    }
}

/// Minimal real-git fixture for the on-disk worktree removal tests.
private enum GitFixture {
    /// Creates a temp repository with one commit and returns its (symlink-
    /// resolved) absolute path. Symlinks are resolved so the test's paths match
    /// the absolute paths git itself reports for worktrees.
    static func makeRepo() throws -> String {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-wt-test-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let repo = base.path
        run(["init", "-q"], in: repo)
        try "hello\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        run(["add", "."], in: repo)
        run(
            [
                "-c", "user.email=test@cmux.dev",
                "-c", "user.name=cmux test",
                "-c", "commit.gpgsign=false",
                "commit", "-q", "-m", "init",
            ],
            in: repo
        )
        return repo
    }

    static func cleanUp(_ repo: String) {
        // Remove the temp base (repo is <base>; nuke the whole tree).
        try? FileManager.default.removeItem(atPath: repo)
    }

    @discardableResult
    static func run(_ arguments: [String], in directory: String) -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "failed to launch git: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
