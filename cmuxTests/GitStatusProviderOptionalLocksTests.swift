import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression tests for https://github.com/manaflow-ai/cmux/issues/4779.
///
/// The file explorer polls `git status` on every FSEvents burst. A bare
/// `git status` opportunistically refreshes the stat cache and rewrites
/// `.git/index` under `.git/index.lock`, which makes the user's own
/// `git rebase`/`git commit` fail with "Unable to create index.lock:
/// File exists". Observing a repo must never take that lock.
@Suite("GitStatusProvider optional locks")
struct GitStatusProviderOptionalLocksTests {

    @Test func fetchStatusDoesNotRewriteGitIndex() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-optional-locks-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try runGit(["init", "--quiet"], in: root)
        try runGit(["config", "user.email", "test@cmux.invalid"], in: root)
        try runGit(["config", "user.name", "cmux tests"], in: root)
        let tracked = root.appendingPathComponent("tracked.txt")
        try Data("hello\n".utf8).write(to: tracked)
        try runGit(["add", "tracked.txt"], in: root)
        try runGit(["commit", "--quiet", "-m", "initial"], in: root)

        // Make the index stat cache stale without changing content. A bare
        // `git status` refreshes the cache and rewrites .git/index (taking
        // index.lock); an observing status must leave the index untouched.
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: tracked.path
        )

        let indexURL = root.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: indexURL)

        // fetchStatus keys results by the repo root git itself reports
        // (/private/var/..., not the /var/... spelling of the temp dir), so
        // query git rather than resolving symlinks ourselves.
        let resolvedRoot = try gitOutput(["rev-parse", "--show-toplevel"], in: root)
        let cleanStatus = GitStatusProvider.fetchStatus(directory: resolvedRoot)
        #expect(cleanStatus.isEmpty)

        // Status output must still be correct with the lock-free invocation.
        try Data("changed\n".utf8).write(to: tracked)
        let untracked = root.appendingPathComponent("untracked.txt")
        try Data("new\n".utf8).write(to: untracked)
        let dirtyStatus = GitStatusProvider.fetchStatus(directory: resolvedRoot)
        #expect(dirtyStatus["\(resolvedRoot)/tracked.txt"] == .modified)
        #expect(dirtyStatus["\(resolvedRoot)/untracked.txt"] == .untracked)

        let indexAfter = try Data(contentsOf: indexURL)
        #expect(
            indexAfter == indexBefore,
            "observing git status must not rewrite .git/index (it takes index.lock and races user git commands)"
        )
        #expect(!fileManager.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }

    private func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
        let output = try #require(String(bytes: data, encoding: .utf8))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
