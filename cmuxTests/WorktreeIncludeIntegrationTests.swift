import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7899.
@Suite("Worktree include integration")
struct WorktreeIncludeIntegrationTests {
    @Test("generated sample directory cannot be replaced by an included symlink")
    func generatedSampleDirectoryCannotEscapeWorktree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-worktree-sample-reservation-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("Project", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let outsideIndex = outside.appendingPathComponent("index.html")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "outside\n".write(to: outsideIndex, atomically: true, encoding: .utf8)
        try runGit(["init"], in: projectRoot)
        try "cmux-sample-dev\n".write(
            to: projectRoot.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "cmux-sample-dev\n".write(
            to: projectRoot.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try "hello\n".write(
            to: projectRoot.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: projectRoot.appendingPathComponent("cmux-sample-dev"),
            withDestinationURL: outside
        )
        try runGit(["add", ".gitignore", ".worktreeinclude", "README.md"], in: projectRoot)
        try runGit([
            "-c", "user.name=cmux Test",
            "-c", "user.email=cmux@example.invalid",
            "commit", "-m", "initial",
        ], in: projectRoot)

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(projectRootPath: projectRoot.path)
        let generatedSample = URL(fileURLWithPath: result.worktreePath)
            .appendingPathComponent("cmux-sample-dev", isDirectory: true)
        let generatedValues = try generatedSample.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )

        #expect(generatedValues.isDirectory == true)
        #expect(generatedValues.isSymbolicLink != true)
        #expect(try String(contentsOf: outsideIndex, encoding: .utf8) == "outside\n")
    }

    @Test("sidebar worktree creation copies ignored files listed in .worktreeinclude")
    func sidebarCreationCopiesIncludedIgnoredFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-worktree-include-integration-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("Project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try runGit(["init"], in: projectRoot)
        try "*.env\n".write(
            to: projectRoot.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try ".env\n".write(
            to: projectRoot.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try "hello\n".write(
            to: projectRoot.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "secret=value\n".write(
            to: projectRoot.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", ".gitignore", ".worktreeinclude", "README.md"], in: projectRoot)
        try runGit([
            "-c", "user.name=cmux Test",
            "-c", "user.email=cmux@example.invalid",
            "commit", "-m", "initial",
        ], in: projectRoot)

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(projectRootPath: projectRoot.path)
        let copiedEnvironment = try String(
            contentsOf: URL(fileURLWithPath: result.worktreePath).appendingPathComponent(".env"),
            encoding: .utf8
        )

        #expect(copiedEnvironment == "secret=value\n")
    }

    @Test(
        "cancelled sidebar worktree creation terminates Git and removes its artifacts",
        .timeLimit(.minutes(1))
    )
    func cancelledCreationRollsBackGitArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-worktree-cancellation-integration-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("Project", isDirectory: true)
        let marker = root.appendingPathComponent("post-checkout-started")
        let hookPIDFile = root.appendingPathComponent("post-checkout-pid")
        let releasePipe = root.appendingPathComponent("post-checkout-release")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try runGit(["init"], in: projectRoot)
        try "hello\n".write(
            to: projectRoot.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"], in: projectRoot)
        try runGit([
            "-c", "user.name=cmux Test",
            "-c", "user.email=cmux@example.invalid",
            "commit", "-m", "initial",
        ], in: projectRoot)

        let hooks = projectRoot.appendingPathComponent(".git/hooks", isDirectory: true)
        let hook = hooks.appendingPathComponent("post-checkout")
        let hookScript = """
        #!/bin/sh
        trap '' TERM HUP
        echo $$ > \(shellEscaped(hookPIDFile.path))
        touch \(shellEscaped(marker.path))
        IFS= read -r _ < \(shellEscaped(releasePipe.path))
        """
        try hookScript.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let makePipe = Process()
        makePipe.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
        makePipe.arguments = [releasePipe.path]
        try makePipe.run()
        makePipe.waitUntilExit()
        #expect(makePipe.terminationStatus == 0)

        let watcher = FileWatcher(path: marker.path)
        let creation = Task {
            try await CmuxExtensionWorktreePrototype.createWorktree(projectRootPath: projectRoot.path)
        }
        for await _ in watcher.events {
            if FileManager.default.fileExists(atPath: marker.path) { break }
        }
        await watcher.stop()
        let hookPID = try #require(pid_t(
            String(contentsOf: hookPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer {
            if Darwin.kill(hookPID, 0) == 0 {
                _ = Darwin.kill(hookPID, SIGKILL)
            }
        }

        let fallbackRelease = Task.detached {
            // Bounds the pre-fix failure so the test reports instead of leaking the blocked hook.
            try await Task.sleep(for: .seconds(10))
            let handle = try FileHandle(forWritingTo: releasePipe)
            try handle.write(contentsOf: Data("continue\n".utf8))
            try handle.close()
        }
        let cancellationStarted = ContinuousClock.now
        creation.cancel()

        do {
            _ = try await creation.value
            Issue.record("Cancelled worktree creation unexpectedly succeeded.")
        } catch is CancellationError {
            // Expected: cancellation after `git worktree add` triggers rollback.
        } catch {
            Issue.record("Cancelled worktree creation returned an unexpected error: \(error)")
        }
        let cancellationDuration = cancellationStarted.duration(to: .now)
        fallbackRelease.cancel()

        let worktreeList = try runGit(["worktree", "list", "--porcelain"], in: projectRoot)
        let branches = try runGit(["branch", "--list", "cmux-sidebar-*"], in: projectRoot)
        #expect(cancellationDuration < .seconds(5))
        #expect(Darwin.kill(hookPID, 0) == -1)
        #expect(errno == ESRCH)
        #expect(!worktreeList.contains("/.cmux/worktrees/"))
        #expect(branches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "WorktreeIncludeIntegrationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
        return output
    }

    private func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
