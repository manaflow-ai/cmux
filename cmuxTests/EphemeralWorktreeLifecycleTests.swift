import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class EphemeralWorktreeLifecycleTests: XCTestCase {
    func testCleanWorktreeCleanupRemovesWorktreeAndSessionBranch() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }

        let registry = EphemeralWorktreeRegistry(storeURL: fixture.registryURL)
        let record = try registry.create(sourceDirectory: fixture.repositoryURL.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: record.worktreePath))
        XCTAssertTrue(try fixture.branchExists(record.branchName))

        let result = try registry.cleanup(record)

        XCTAssertFalse(result.dirtyBeforeCleanup)
        XCTAssertNil(result.abandonedBranchName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.worktreePath))
        XCTAssertFalse(try fixture.branchExists(record.branchName))
        XCTAssertTrue(registry.records().isEmpty)
    }

    func testDirtyWorktreeCleanupSnapshotsChangesBeforeRemoval() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }

        let registry = EphemeralWorktreeRegistry(storeURL: fixture.registryURL)
        let record = try registry.create(sourceDirectory: fixture.repositoryURL.path)
        let noteURL = URL(fileURLWithPath: record.worktreePath)
            .appendingPathComponent("notes.txt", isDirectory: false)
        try "preserved\n".write(to: noteURL, atomically: true, encoding: .utf8)

        let result = try registry.cleanup(record)
        let abandonedBranchName = try XCTUnwrap(result.abandonedBranchName)

        XCTAssertTrue(result.dirtyBeforeCleanup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.worktreePath))
        XCTAssertFalse(try fixture.branchExists(record.branchName))
        XCTAssertTrue(try fixture.branchExists(abandonedBranchName))
        XCTAssertEqual(try fixture.show("\(abandonedBranchName):notes.txt"), "preserved\n")
    }

    func testBlockPolicyPreservesDirtyWorktreeWithoutConfirmation() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }

        let registry = EphemeralWorktreeRegistry(storeURL: fixture.registryURL)
        let record = try registry.create(
            sourceDirectory: fixture.repositoryURL.path,
            cleanupPolicy: .block
        )
        let noteURL = URL(fileURLWithPath: record.worktreePath)
            .appendingPathComponent("notes.txt", isDirectory: false)
        try "not removed\n".write(to: noteURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try registry.cleanup(record)) { error in
            XCTAssertTrue(error is EphemeralWorktreeLifecycleError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.worktreePath))
        XCTAssertEqual(registry.records().map(\.sessionId), [record.sessionId])
    }

    func testOrphanReconciliationUsesSnapshotSafeguard() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }

        let registry = EphemeralWorktreeRegistry(storeURL: fixture.registryURL)
        let record = try registry.create(sourceDirectory: fixture.repositoryURL.path)
        let noteURL = URL(fileURLWithPath: record.worktreePath)
            .appendingPathComponent("orphan.txt", isDirectory: false)
        try "orphan preserved\n".write(to: noteURL, atomically: true, encoding: .utf8)

        let results = registry.reconcileOrphans(activeSessionIds: [])
        let result = try XCTUnwrap(results.first).get()
        let abandonedBranchName = try XCTUnwrap(result.abandonedBranchName)

        XCTAssertFalse(FileManager.default.fileExists(atPath: record.worktreePath))
        XCTAssertFalse(try fixture.branchExists(record.branchName))
        XCTAssertTrue(try fixture.branchExists(abandonedBranchName))
        XCTAssertEqual(try fixture.show("\(abandonedBranchName):orphan.txt"), "orphan preserved\n")
    }

    func testBlockPolicyOrphanReconciliationSnapshotsAndRemoves() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }

        let registry = EphemeralWorktreeRegistry(storeURL: fixture.registryURL)
        let record = try registry.create(
            sourceDirectory: fixture.repositoryURL.path,
            cleanupPolicy: .block
        )
        let noteURL = URL(fileURLWithPath: record.worktreePath)
            .appendingPathComponent("blocked-orphan.txt", isDirectory: false)
        try "blocked orphan preserved\n".write(to: noteURL, atomically: true, encoding: .utf8)

        let results = registry.reconcileOrphans(activeSessionIds: [])
        let result = try XCTUnwrap(results.first).get()
        let abandonedBranchName = try XCTUnwrap(result.abandonedBranchName)

        XCTAssertFalse(FileManager.default.fileExists(atPath: record.worktreePath))
        XCTAssertFalse(try fixture.branchExists(record.branchName))
        XCTAssertTrue(try fixture.branchExists(abandonedBranchName))
        XCTAssertEqual(try fixture.show("\(abandonedBranchName):blocked-orphan.txt"), "blocked orphan preserved\n")
        XCTAssertTrue(registry.records().isEmpty)
    }
}

private final class GitFixture {
    let rootURL: URL
    let repositoryURL: URL
    let registryURL: URL

    init() throws {
        try Self.requireGit()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-worktree-tests-\(UUID().uuidString)", isDirectory: true)
        repositoryURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        registryURL = rootURL
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("worktrees.json", isDirectory: false)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try Self.runGit(["-C", repositoryURL.path, "init"])
        try Self.runGit(["-C", repositoryURL.path, "config", "user.name", "cmux tests"])
        try Self.runGit(["-C", repositoryURL.path, "config", "user.email", "cmux-tests@example.invalid"])
        let readmeURL = repositoryURL.appendingPathComponent("README.md", isDirectory: false)
        try "# fixture\n".write(to: readmeURL, atomically: true, encoding: .utf8)
        try Self.runGit(["-C", repositoryURL.path, "add", "README.md"])
        try Self.runGit(["-C", repositoryURL.path, "commit", "-m", "initial"])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func branchExists(_ branchName: String) throws -> Bool {
        let result = try Self.runGitResult([
            "-C", repositoryURL.path,
            "show-ref",
            "--verify",
            "--quiet",
            "refs/heads/\(branchName)",
        ])
        return result.exitCode == 0
    }

    func show(_ revisionPath: String) throws -> String {
        try Self.runGit(["-C", repositoryURL.path, "show", revisionPath])
    }

    private static func requireGit() throws {
        let result = try runGitResult(["--version"])
        if result.exitCode != 0 {
            throw XCTSkip("git is not available")
        }
    }

    @discardableResult
    private static func runGit(_ arguments: [String]) throws -> String {
        let result = try runGitResult(arguments)
        guard result.exitCode == 0 else {
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(result.output)")
            throw EphemeralWorktreeLifecycleError.commandFailed(
                command: "git \(arguments.joined(separator: " "))",
                exitCode: result.exitCode,
                output: result.output
            )
        }
        return result.output
    }

    private static func runGitResult(_ arguments: [String]) throws -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}
