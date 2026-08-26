import Darwin
import Dispatch
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
            projectRootPath: "/tmp/project",
            worktreePath: "/tmp/project/.cmux/worktrees/cmux-sidebar-123",
            branchName: "cmux-sidebar-123",
            workspaceTitle: "cmux-sidebar-123",
            createdHead: "0000000000000000000000000000000000000000",
            generatedArtifactRelativePath: "cmux-sample-dev/index.html",
            generatedArtifactContents: Data(),
            worktreeDeviceID: nil,
            worktreeFileID: nil,
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

    @Test("command capture keeps successful stderr out of stdout")
    func commandCaptureSeparatesStandardError() async throws {
        let output = try await CmuxExtensionWorktreePrototype.runCapturingOutput(
            "sh",
            ["-c", "printf 'expected'; printf 'warning' >&2"]
        )

        #expect(String(data: output, encoding: .utf8) == "expected")
    }

    @Test("command failures do not expose subprocess diagnostics")
    func commandFailurePayloadIsSanitized() async {
        let privateDiagnostic = "/private/worktree/secret"
        do {
            _ = try await CmuxExtensionWorktreePrototype.runCapturingOutput(
                "sh",
                ["-c", "printf '\(privateDiagnostic)' >&2; exit 7"],
                failureDescription: "Could not create worktree."
            )
            Issue.record("Expected command failure")
        } catch {
            let error = error as NSError
            #expect(error.domain == "CmuxExtensionWorktreePrototype")
            #expect(error.localizedDescription == "Could not create worktree.")
            #expect(!String(describing: error.userInfo).contains(privateDiagnostic))
            #expect(error.userInfo["CmuxExtensionWorktreePrototypeDetails"] == nil)
        }
    }

    @Test("unclaimed worktree rollback removes checkout and branch")
    func unclaimedWorktreeRollbackRemovesCheckoutAndBranch() async throws {
        let fileManager = FileManager.default
        let projectRoot = try makeTemporaryRepository(label: "unchanged")
        defer { try? fileManager.removeItem(at: projectRoot) }

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(
            projectRootPath: projectRoot.path
        )
        #expect(fileManager.fileExists(atPath: result.worktreePath))
        #expect(try branchExists(result.branchName, projectRoot: projectRoot))

        try await result.rollbackUnclaimedWorktree()

        #expect(!fileManager.fileExists(atPath: result.worktreePath))
        #expect(try !branchExists(result.branchName, projectRoot: projectRoot))
    }

    @Test("rollback accepts a symlinked checkout path")
    func rollbackAcceptsSymlinkedCheckoutPath() async throws {
        let fileManager = FileManager.default
        let projectRoot = try makeTemporaryRepository(label: "symlink-target")
        let projectRootAlias = projectRoot
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(projectRoot.lastPathComponent)-alias-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? fileManager.removeItem(at: projectRootAlias)
            try? fileManager.removeItem(at: projectRoot)
        }
        try fileManager.createSymbolicLink(at: projectRootAlias, withDestinationURL: projectRoot)

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(
            projectRootPath: projectRootAlias.path
        )
        let resolvedWorktreePath = URL(fileURLWithPath: result.worktreePath, isDirectory: true)
            .resolvingSymlinksInPath()
            .path

        try await result.rollbackUnclaimedWorktree()

        #expect(!fileManager.fileExists(atPath: resolvedWorktreePath))
        #expect(try !branchExists(result.branchName, projectRoot: projectRoot))
    }

    @Test("rollback retains checkout when tracked, untracked, or ignored content changes")
    func rollbackRetainsCheckoutWhenWorktreeContentChanges() async throws {
        let fileManager = FileManager.default
        let projectRoot = try makeTemporaryRepository(label: "dirty")
        defer { try? fileManager.removeItem(at: projectRoot) }

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(
            projectRootPath: projectRoot.path
        )
        let worktree = URL(fileURLWithPath: result.worktreePath, isDirectory: true)
        try "modified seed\n".write(
            to: worktree.appendingPathComponent("seed.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "untracked data\n".write(
            to: worktree.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )
        let ignoredDirectory = worktree.appendingPathComponent(".cmux", isDirectory: true)
        try fileManager.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
        try "ignored data\n".write(
            to: ignoredDirectory.appendingPathComponent("user-data.txt"),
            atomically: true,
            encoding: .utf8
        )

        await expectRollbackRefused(result)

        #expect(fileManager.fileExists(atPath: result.worktreePath))
        #expect(try branchExists(result.branchName, projectRoot: projectRoot))
        #expect(
            try String(contentsOf: worktree.appendingPathComponent("seed.txt"), encoding: .utf8)
                == "modified seed\n"
        )
        #expect(fileManager.fileExists(atPath: worktree.appendingPathComponent("notes.txt").path))
        #expect(fileManager.fileExists(atPath: ignoredDirectory.appendingPathComponent("user-data.txt").path))
    }

    @Test("rollback refuses a replacement checkout at the original path")
    func rollbackRefusesReplacementCheckoutAtOriginalPath() async throws {
        let fileManager = FileManager.default
        let projectRoot = try makeTemporaryRepository(label: "replacement")
        defer { try? fileManager.removeItem(at: projectRoot) }

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(
            projectRootPath: projectRoot.path
        )
        try runGit([
            "-C", projectRoot.path,
            "worktree", "remove", "--force", result.worktreePath,
        ])
        try runGit([
            "-C", projectRoot.path,
            "worktree", "add", result.worktreePath, result.branchName,
        ])
        let replacementArtifact = URL(fileURLWithPath: result.worktreePath, isDirectory: true)
            .appendingPathComponent(result.generatedArtifactRelativePath)
        try fileManager.createDirectory(
            at: replacementArtifact.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.generatedArtifactContents.write(to: replacementArtifact)

        await expectRollbackRefused(result)

        #expect(fileManager.fileExists(atPath: result.worktreePath))
        #expect(try branchExists(result.branchName, projectRoot: projectRoot))
        #expect(try Data(contentsOf: replacementArtifact) == result.generatedArtifactContents)
    }

    @Test("rollback retains checkout when generated artifact changes")
    func rollbackRetainsCheckoutWhenGeneratedArtifactChanges() async throws {
        let fileManager = FileManager.default
        let projectRoot = try makeTemporaryRepository(label: "artifact")
        defer { try? fileManager.removeItem(at: projectRoot) }

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(
            projectRootPath: projectRoot.path
        )
        let artifact = URL(fileURLWithPath: result.worktreePath, isDirectory: true)
            .appendingPathComponent("cmux-sample-dev/index.html")
        let changedContents = Data("user changed generated sample\n".utf8)
        try changedContents.write(to: artifact, options: .atomic)

        await expectRollbackRefused(result)

        #expect(fileManager.fileExists(atPath: result.worktreePath))
        #expect(try branchExists(result.branchName, projectRoot: projectRoot))
        #expect(try Data(contentsOf: artifact) == changedContents)
    }

    @Test("locked worktree rollback preserves state and can be retried")
    func lockedWorktreeRollbackPreservesStateAndCanBeRetried() async throws {
        let fileManager = FileManager.default
        let projectRoot = try makeTemporaryRepository(label: "locked")
        defer { try? fileManager.removeItem(at: projectRoot) }

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(
            projectRootPath: projectRoot.path
        )
        let artifact = URL(fileURLWithPath: result.worktreePath, isDirectory: true)
            .appendingPathComponent(result.generatedArtifactRelativePath)
        try runGit([
            "-C", projectRoot.path,
            "worktree", "lock", "--reason", "cmux rollback regression", result.worktreePath,
        ])

        do {
            try await result.rollbackUnclaimedWorktree()
            Issue.record("Rollback removed a locked worktree")
        } catch {
            let error = error as NSError
            #expect(error.domain == "CmuxExtensionWorktreePrototype")
        }

        #expect(fileManager.fileExists(atPath: result.worktreePath))
        #expect(fileManager.fileExists(atPath: artifact.path))
        #expect(try branchExists(result.branchName, projectRoot: projectRoot))

        try runGit([
            "-C", projectRoot.path,
            "worktree", "unlock", result.worktreePath,
        ])
        try await result.rollbackUnclaimedWorktree()

        #expect(!fileManager.fileExists(atPath: result.worktreePath))
        #expect(try !branchExists(result.branchName, projectRoot: projectRoot))
    }

    @Test("branch deletion failure retains a recoverable artifact backup")
    func branchDeletionFailureRetainsRecoverableArtifactBackup() async throws {
        let fileManager = FileManager.default
        let projectRoot = try makeTemporaryRepository(label: "branch-lock")
        defer { try? fileManager.removeItem(at: projectRoot) }

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(
            projectRootPath: projectRoot.path
        )
        let branchLock = projectRoot
            .appendingPathComponent(".git/refs/heads", isDirectory: true)
            .appendingPathComponent(result.branchName + ".lock")
        try Data("held by rollback regression\n".utf8).write(to: branchLock)

        do {
            try await result.rollbackUnclaimedWorktree()
            Issue.record("Rollback deleted a branch whose ref was locked")
        } catch {
            let error = error as NSError
            #expect(error.domain == "CmuxExtensionWorktreePrototype")
        }

        #expect(!fileManager.fileExists(atPath: result.worktreePath))
        #expect(try branchExists(result.branchName, projectRoot: projectRoot))

        let worktreeRoot = URL(fileURLWithPath: result.worktreePath, isDirectory: true)
            .deletingLastPathComponent()
        let rollbackBackups = try fileManager.contentsOfDirectory(
            at: worktreeRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".cmux-rollback-") }
        let artifactBackup = try #require(rollbackBackups.first)
        #expect(rollbackBackups.count == 1)
        #expect(try Data(contentsOf: artifactBackup) == result.generatedArtifactContents)
    }

    @Test("rollback retains edits written through an open artifact descriptor", .timeLimit(.minutes(1)))
    func rollbackRetainsEditsWrittenThroughOpenArtifactDescriptor() async throws {
        let fileManager = FileManager.default
        let projectRoot = try makeTemporaryRepository(label: "open-artifact")
        defer { try? fileManager.removeItem(at: projectRoot) }

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(
            projectRootPath: projectRoot.path
        )
        let artifact = URL(fileURLWithPath: result.worktreePath, isDirectory: true)
            .appendingPathComponent(result.generatedArtifactRelativePath)
        let artifactDescriptor = Darwin.open(artifact.path, O_RDWR)
        guard artifactDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let changedContents = Data("user edit written through an open descriptor\n".utf8)
        let mutation = AsyncStream<Int32>.makeStream()
        let renameSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: artifactDescriptor,
            eventMask: .rename,
            queue: DispatchQueue(label: "com.cmux.tests.extension-worktree-artifact-rename")
        )
        renameSource.setEventHandler {
            let mutationStatus = changedContents.withUnsafeBytes { bytes -> Int32 in
                guard let baseAddress = bytes.baseAddress else { return EINVAL }
                let written = Darwin.pwrite(
                    artifactDescriptor,
                    baseAddress,
                    bytes.count,
                    0
                )
                guard written == bytes.count else { return errno == 0 ? EIO : errno }
                return Darwin.ftruncate(artifactDescriptor, off_t(bytes.count)) == 0 ? 0 : errno
            }
            mutation.continuation.yield(mutationStatus)
            mutation.continuation.finish()
        }
        renameSource.resume()
        defer {
            renameSource.cancel()
            Darwin.close(artifactDescriptor)
        }

        var rollbackError: NSError?
        do {
            try await result.rollbackUnclaimedWorktree()
        } catch {
            rollbackError = error as NSError
        }

        let mutationStatus = await withTaskGroup(of: Int32?.self, returning: Int32?.self) { group in
            group.addTask {
                var mutationIterator = mutation.stream.makeAsyncIterator()
                await mutationIterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let firstResult = await group.next() ?? nil
            if firstResult == nil {
                mutation.continuation.finish()
            }
            group.cancelAll()
            return firstResult
        }
        #expect(mutationStatus == 0)
        #expect(rollbackError?.domain == "CmuxExtensionWorktreePrototype")
        #expect(rollbackError?.code == 3)
        #expect(!fileManager.fileExists(atPath: result.worktreePath))
        #expect(try !branchExists(result.branchName, projectRoot: projectRoot))

        let worktreeRoot = URL(fileURLWithPath: result.worktreePath, isDirectory: true)
            .deletingLastPathComponent()
        let rollbackBackups = try fileManager.contentsOfDirectory(
            at: worktreeRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".cmux-rollback-") }
        let artifactBackup = try #require(rollbackBackups.first)
        #expect(rollbackBackups.count == 1)
        #expect(try Data(contentsOf: artifactBackup) == changedContents)
    }

    @Test("rollback retains checkout and branch after a new commit")
    func rollbackRetainsCheckoutAndBranchAfterCommit() async throws {
        let fileManager = FileManager.default
        let projectRoot = try makeTemporaryRepository(label: "commit")
        defer { try? fileManager.removeItem(at: projectRoot) }

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(
            projectRootPath: projectRoot.path
        )
        let worktree = URL(fileURLWithPath: result.worktreePath, isDirectory: true)
        try "committed change\n".write(
            to: worktree.appendingPathComponent("seed.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["-C", worktree.path, "add", "seed.txt"])
        try runGit([
            "-C", worktree.path,
            "-c", "user.name=cmux Tests",
            "-c", "user.email=cmux-tests@example.invalid",
            "commit", "--quiet", "-m", "user commit",
        ])

        await expectRollbackRefused(result)

        #expect(fileManager.fileExists(atPath: result.worktreePath))
        #expect(try branchExists(result.branchName, projectRoot: projectRoot))
        #expect(
            try String(contentsOf: worktree.appendingPathComponent("seed.txt"), encoding: .utf8)
                == "committed change\n"
        )
    }

    private func makeTemporaryRepository(label: String) throws -> URL {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-extension-worktree-rollback-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try runGit(["-C", projectRoot.path, "init", "--quiet"])
        try "seed\n".write(
            to: projectRoot.appendingPathComponent("seed.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["-C", projectRoot.path, "add", "seed.txt"])
        try runGit([
            "-C", projectRoot.path,
            "-c", "user.name=cmux Tests",
            "-c", "user.email=cmux-tests@example.invalid",
            "commit", "--quiet", "-m", "seed",
        ])
        return projectRoot
    }

    private func expectRollbackRefused(_ result: CmuxExtensionWorktreeCreationResult) async {
        do {
            try await result.rollbackUnclaimedWorktree()
            Issue.record("Rollback removed a worktree whose state changed")
        } catch {
            let error = error as NSError
            #expect(error.domain == "CmuxExtensionWorktreePrototype")
            #expect(error.code == 3)
        }
    }

    private func branchExists(_ branchName: String, projectRoot: URL) throws -> Bool {
        try gitStatus([
            "-C", projectRoot.path,
            "show-ref", "--verify", "--quiet", "refs/heads/\(branchName)",
        ]) == 0
    }

    private func runGit(_ arguments: [String]) throws {
        let status = try gitStatus(arguments)
        guard status == 0 else {
            throw NSError(
                domain: "ExtensionWorktreeSpawnArgsTests",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "git command failed with status \(status)"]
            )
        }
    }

    private func gitStatus(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
