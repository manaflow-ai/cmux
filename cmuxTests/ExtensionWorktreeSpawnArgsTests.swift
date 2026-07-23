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

    @Test("unclaimed worktree rollback removes checkout and branch")
    func unclaimedWorktreeRollbackRemovesCheckoutAndBranch() async throws {
        let fileManager = FileManager.default
        let projectRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-extension-worktree-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: projectRoot) }

        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
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

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(
            projectRootPath: projectRoot.path
        )
        #expect(fileManager.fileExists(atPath: result.worktreePath))
        #expect(
            try gitStatus([
                "-C", projectRoot.path,
                "show-ref", "--verify", "--quiet", "refs/heads/\(result.branchName)",
            ]) == 0
        )

        try await result.rollbackUnclaimedWorktree()

        #expect(!fileManager.fileExists(atPath: result.worktreePath))
        #expect(
            try gitStatus([
                "-C", projectRoot.path,
                "show-ref", "--verify", "--quiet", "refs/heads/\(result.branchName)",
            ]) != 0
        )
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
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
