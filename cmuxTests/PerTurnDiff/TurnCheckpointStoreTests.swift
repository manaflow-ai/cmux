import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

@MainActor
final class TurnCheckpointStoreTests: XCTestCase {
    private var tempDir: URL!
    private var workspaceId: UUID!

    override func setUp() async throws {
        // Assign first so tearDown can safely read it even if a later
        // `shell()` throws (git missing, mkdir failure, etc.).
        workspaceId = UUID()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pertd-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        _ = try shell("git init -q", in: tempDir.path)
        _ = try shell("git config user.email 'test@cmux.test'", in: tempDir.path)
        _ = try shell("git config user.name 'cmux test'", in: tempDir.path)
        _ = try shell("touch a.txt && git add a.txt && git -c commit.gpgsign=false commit -q -m initial", in: tempDir.path)
    }

    override func tearDown() async throws {
        if let workspaceId {
            TurnCheckpointStore.removeDiffStateDirectory(workspaceId: workspaceId)
        }
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - gitRoot / gitCommonDir

    func test_gitRoot_returnsRepoRootForFileInRepo() throws {
        let nested = tempDir.appendingPathComponent("sub", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let root = TurnCheckpointStore.gitRoot(containing: nested)
        XCTAssertEqual(URL(fileURLWithPath: root ?? "").standardized.path,
                       URL(fileURLWithPath: tempDir.path).standardized.path)
    }

    func test_gitCommonDir_pointsAtUserGitDir() throws {
        let dir = TurnCheckpointStore.gitCommonDir(for: tempDir.path)
        XCTAssertNotNil(dir)
        XCTAssertTrue(dir!.contains(".git"),
                      "expected gitCommonDir to reference .git, got \(dir ?? "nil")")
    }

    // MARK: - writeTreeIsolated

    func test_writeTreeIsolated_capturesUntrackedFile() throws {
        try "hello".write(toFile: tempDir.appendingPathComponent("untracked.txt").path,
                          atomically: true, encoding: .utf8)
        let sha = try TurnCheckpointStore.writeTreeIsolated(workspaceId: workspaceId, in: tempDir.path)
        XCTAssertEqual(sha.count, 40)
    }

    func test_writeTreeIsolated_doesNotMutateUserIndex() throws {
        try "indexed".write(toFile: tempDir.appendingPathComponent("indexed.txt").path,
                            atomically: true, encoding: .utf8)
        _ = try shell("git add indexed.txt", in: tempDir.path)
        let beforeIndex = try shell("git ls-files --stage", in: tempDir.path)

        try "x".write(toFile: tempDir.appendingPathComponent("scratch.txt").path,
                      atomically: true, encoding: .utf8)
        _ = try TurnCheckpointStore.writeTreeIsolated(workspaceId: workspaceId, in: tempDir.path)

        let afterIndex = try shell("git ls-files --stage", in: tempDir.path)
        XCTAssertEqual(beforeIndex, afterIndex, "real index must be untouched")
    }

    func test_writeTreeIsolated_writesObjectsIntoCmuxStoreNotUserGit() throws {
        try "x".write(toFile: tempDir.appendingPathComponent("z.txt").path,
                      atomically: true, encoding: .utf8)
        let sha = try TurnCheckpointStore.writeTreeIsolated(workspaceId: workspaceId, in: tempDir.path)

        let userObjectPath = tempDir.appendingPathComponent(".git/objects").path
            + "/\(sha.prefix(2))/\(sha.dropFirst(2))"
        XCTAssertFalse(FileManager.default.fileExists(atPath: userObjectPath),
                       "tree object must NOT live in the user's .git/objects/")

        let cmuxStore = TurnCheckpointStore.diffStateDirectory(
            workspaceId: workspaceId, repoRoot: tempDir.path
        )
        let cmuxObjectPath = cmuxStore.appendingPathComponent("\(sha.prefix(2))/\(sha.dropFirst(2))").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: cmuxObjectPath),
                      "tree object must live in the cmux-owned object store")
    }

    // MARK: - bestEffortDiff tier behavior

    func test_bestEffortDiff_tier1_baselineVsCurrent() throws {
        // Capture baseline tree, edit, then diff against baseline.
        let baseline = try TurnCheckpointStore.writeTreeIsolated(workspaceId: workspaceId, in: tempDir.path)
        try "newcontent".write(toFile: tempDir.appendingPathComponent("new.txt").path,
                               atomically: true, encoding: .utf8)
        let (diff, tier) = TurnCheckpointStore.bestEffortDiff(
            workspaceId: workspaceId, baselineTreeSha: baseline, in: tempDir.path
        )
        XCTAssertEqual(tier, .sessionBaseline)
        XCTAssertTrue(diff.contains("new.txt"))
    }

    func test_bestEffortDiff_tier2_headFallback_whenNoBaseline() throws {
        try "headplus".write(toFile: tempDir.appendingPathComponent("after.txt").path,
                             atomically: true, encoding: .utf8)
        let (diff, tier) = TurnCheckpointStore.bestEffortDiff(
            workspaceId: workspaceId, baselineTreeSha: nil, in: tempDir.path
        )
        XCTAssertEqual(tier, .head)
        XCTAssertTrue(diff.contains("after.txt"))
    }

    // MARK: - Worktree noise filter

    func test_filterWorktreesFromDiff_stripsClaudeWorktreesBlocks() {
        let raw = """
        diff --git a/README.md b/README.md
        @@ -1 +1,2 @@
         hi
        +bye
        diff --git a/.claude/worktrees/agent-X/foo b/.claude/worktrees/agent-X/foo
        @@ -0,0 +1 @@
        +noise
        diff --git a/src/x.swift b/src/x.swift
        @@ -1 +1 @@
        -a
        +b
        """
        let filtered = TurnCheckpointStore.filterWorktreesFromDiff(raw)
        XCTAssertTrue(filtered.contains("README.md"))
        XCTAssertTrue(filtered.contains("src/x.swift"))
        XCTAssertFalse(filtered.contains("agent-X"),
                       "expected .claude/worktrees/* block to be stripped")
    }

    func test_filterWorktreesFromDiff_stripsBareWorktreesPrefixToo() {
        let raw = """
        diff --git a/README.md b/README.md
        @@ -1 +1 @@
        -x
        +y
        diff --git a/.worktrees/foo/file b/.worktrees/foo/file
        @@ -0,0 +1 @@
        +noise
        """
        let filtered = TurnCheckpointStore.filterWorktreesFromDiff(raw)
        XCTAssertTrue(filtered.contains("README.md"))
        XCTAssertFalse(filtered.contains(".worktrees/foo"))
    }

    func test_filterWorktreesFromDiff_passthroughWhenNoMatches() {
        let raw = """
        diff --git a/x b/x
        @@ -1 +1 @@
        -a
        +b
        """
        XCTAssertEqual(TurnCheckpointStore.filterWorktreesFromDiff(raw), raw)
    }

    // MARK: - Helpers

    private func shell(_ command: String, in dir: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        try p.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "shell", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
