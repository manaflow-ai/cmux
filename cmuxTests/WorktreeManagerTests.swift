import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorktreeManagerTests: XCTestCase {
    // MARK: - Parser tests (no git required)

    func testParsePorcelainSingleBranchedWorktree() {
        let output = """
        worktree /tmp/main
        HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        branch refs/heads/main

        """
        let records = WorktreeManager.parseListPorcelain(output)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].path, "/tmp/main")
        XCTAssertEqual(records[0].head, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(records[0].branch, "main")
        XCTAssertFalse(records[0].isDetached)
        XCTAssertFalse(records[0].isBare)
    }

    func testParsePorcelainDetachedAndLocked() {
        let output = """
        worktree /tmp/a
        HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        detached

        worktree /tmp/b
        HEAD cccccccccccccccccccccccccccccccccccccccc
        branch refs/heads/feat/x
        locked reason

        """
        let records = WorktreeManager.parseListPorcelain(output)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[0].isDetached)
        XCTAssertNil(records[0].branch)
        XCTAssertFalse(records[1].isDetached)
        XCTAssertEqual(records[1].branch, "feat/x")
        XCTAssertTrue(records[1].isLocked)
    }

    func testParsePorcelainBareAndPrunable() {
        let output = """
        worktree /tmp/bare
        bare

        worktree /tmp/old
        HEAD dddddddddddddddddddddddddddddddddddddddd
        branch refs/heads/old
        prunable gitdir file points to non-existent location

        """
        let records = WorktreeManager.parseListPorcelain(output)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[0].isBare)
        XCTAssertTrue(records[1].isPrunable)
    }

    func testParsePorcelainEmpty() {
        XCTAssertEqual(WorktreeManager.parseListPorcelain(""), [])
    }

    // MARK: - Runtime tests (real git)

    private func gitAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: WorktreeManager.gitExecutablePath)
    }

    /// Spin up a fresh repo in a unique temp directory. Returns the repo
    /// toplevel. The directory is registered for cleanup on test teardown.
    private func makeTempRepo() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-worktree-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempDirs.append(base)

        let repo = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let cwd = repo.path

        _ = try WorktreeManager.runGit(args: ["init", "-q", "-b", "main"], cwd: cwd)
        // Configure committer identity so commit succeeds in CI sandboxes
        // that don't inherit a global user.email.
        _ = try WorktreeManager.runGit(args: ["config", "user.email", "test@cmux.local"], cwd: cwd)
        _ = try WorktreeManager.runGit(args: ["config", "user.name", "cmux test"], cwd: cwd)
        let readme = repo.appendingPathComponent("README.md")
        try "hello\n".write(to: readme, atomically: true, encoding: .utf8)
        _ = try WorktreeManager.runGit(args: ["add", "README.md"], cwd: cwd)
        _ = try WorktreeManager.runGit(args: ["commit", "-q", "-m", "init"], cwd: cwd)
        return repo
    }

    private var tempDirs: [URL] = []

    override func tearDown() {
        for url in tempDirs {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    func testAddCreatesWorktreeAndBranch() throws {
        guard gitAvailable() else { throw XCTSkip("git not available on this runner") }
        let repo = try makeTempRepo()
        let wt = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-feat-x")

        let record = try WorktreeManager.add(
            repoPath: repo.path,
            worktreePath: wt.path,
            branch: "feat/x"
        )

        XCTAssertEqual(record.branch, "feat/x")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path))
        let head = try WorktreeManager.runGit(args: ["rev-parse", "--abbrev-ref", "HEAD"], cwd: wt.path)
        XCTAssertEqual(head.trimmingCharacters(in: .whitespacesAndNewlines), "feat/x")

        let listed = try WorktreeManager.list(repoPath: repo.path)
        XCTAssertTrue(listed.contains { $0.branch == "feat/x" })
    }

    func testAddRefusesWhenPathExists() throws {
        guard gitAvailable() else { throw XCTSkip("git not available on this runner") }
        let repo = try makeTempRepo()
        let wt = repo.deletingLastPathComponent().appendingPathComponent("blocker")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try WorktreeManager.add(
                repoPath: repo.path,
                worktreePath: wt.path,
                branch: "feat/y"
            )
        ) { error in
            guard case WorktreeManager.Failure.worktreePathExists = error else {
                return XCTFail("expected worktreePathExists, got \(error)")
            }
        }
    }

    func testAddRefusesWhenBranchExists() throws {
        guard gitAvailable() else { throw XCTSkip("git not available on this runner") }
        let repo = try makeTempRepo()
        _ = try WorktreeManager.runGit(args: ["branch", "feat/dup"], cwd: repo.path)
        let wt = repo.deletingLastPathComponent().appendingPathComponent("wt-dup")

        XCTAssertThrowsError(
            try WorktreeManager.add(
                repoPath: repo.path,
                worktreePath: wt.path,
                branch: "feat/dup"
            )
        ) { error in
            guard case WorktreeManager.Failure.branchAlreadyExists = error else {
                return XCTFail("expected branchAlreadyExists, got \(error)")
            }
        }
    }

    func testRemoveDeletesWorktree() throws {
        guard gitAvailable() else { throw XCTSkip("git not available on this runner") }
        let repo = try makeTempRepo()
        let wt = repo.deletingLastPathComponent().appendingPathComponent("wt-rm")
        _ = try WorktreeManager.add(
            repoPath: repo.path,
            worktreePath: wt.path,
            branch: "feat/rm"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path))

        try WorktreeManager.remove(repoPath: repo.path, worktreePath: wt.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))

        let listed = try WorktreeManager.list(repoPath: repo.path)
        XCTAssertFalse(listed.contains { $0.path.hasSuffix("wt-rm") })
    }

    func testSnapshotCreatesRecoveryBranchAtHead() throws {
        guard gitAvailable() else { throw XCTSkip("git not available on this runner") }
        let repo = try makeTempRepo()
        let wt = repo.deletingLastPathComponent().appendingPathComponent("wt-snap")
        _ = try WorktreeManager.add(
            repoPath: repo.path,
            worktreePath: wt.path,
            branch: "feat/snap"
        )
        let headSha = try WorktreeManager.runGit(args: ["rev-parse", "HEAD"], cwd: wt.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let snapTarget = try WorktreeManager.snapshot(
            worktreePath: wt.path,
            mainRepoPath: repo.path,
            snapshotBranch: "cmux/abandoned/test-clean"
        )

        XCTAssertEqual(snapTarget, headSha)
        let resolved = try WorktreeManager.runGit(
            args: ["rev-parse", "cmux/abandoned/test-clean"],
            cwd: repo.path
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(resolved, headSha)
    }

    func testSnapshotCapturesUncommittedChangesViaStash() throws {
        guard gitAvailable() else { throw XCTSkip("git not available on this runner") }
        let repo = try makeTempRepo()
        let wt = repo.deletingLastPathComponent().appendingPathComponent("wt-snap-dirty")
        _ = try WorktreeManager.add(
            repoPath: repo.path,
            worktreePath: wt.path,
            branch: "feat/snap-dirty"
        )
        // Modify a tracked file so `stash create` produces a non-empty stash.
        let readme = wt.appendingPathComponent("README.md")
        try "hello\nplus a dirty line\n".write(to: readme, atomically: true, encoding: .utf8)
        let headSha = try WorktreeManager.runGit(args: ["rev-parse", "HEAD"], cwd: wt.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let snapTarget = try WorktreeManager.snapshot(
            worktreePath: wt.path,
            mainRepoPath: repo.path,
            snapshotBranch: "cmux/abandoned/test-dirty"
        )

        XCTAssertNotEqual(snapTarget, headSha, "stash commit should be a new sha")
        // The stash commit's first parent should be HEAD.
        let parent = try WorktreeManager.runGit(
            args: ["rev-parse", "\(snapTarget)^1"],
            cwd: repo.path
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(parent, headSha)
    }

    func testRepoToplevelResolves() throws {
        guard gitAvailable() else { throw XCTSkip("git not available on this runner") }
        let repo = try makeTempRepo()
        let sub = repo.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let top = try WorktreeManager.repoToplevel(forPath: sub.path)
        let realRepo = (repo.path as NSString).resolvingSymlinksInPath
        let realTop = (top as NSString).resolvingSymlinksInPath
        XCTAssertEqual(realTop, realRepo)
    }

    func testRepoToplevelFailsOutsideRepo() throws {
        guard gitAvailable() else { throw XCTSkip("git not available on this runner") }
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-worktree-tests-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        tempDirs.append(outside)

        XCTAssertThrowsError(try WorktreeManager.repoToplevel(forPath: outside.path)) { error in
            guard case WorktreeManager.Failure.notARepository = error else {
                return XCTFail("expected notARepository, got \(error)")
            }
        }
    }
}
