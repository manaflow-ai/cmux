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

    @Test("setup command is never the workspace's primary process")
    func setupCommandIsNeverPrimaryProcess() {
        let args = makeResult(setupCommand: "cd '/tmp/sample' && python3 -m http.server 4100")
            .workspaceSpawnArgs()

        // A one-shot setup command as the primary process makes the tab die the
        // moment that command exits. The main process must remain the shell.
        #expect(args.initialTerminalCommand == nil)
    }

    @Test("setup command runs as interactive shell input")
    func setupCommandRunsAsShellInput() {
        let setup = "cd '/tmp/sample' && python3 -m http.server 4100"
        let args = makeResult(setupCommand: setup).workspaceSpawnArgs()

        // Delivered as input (with a trailing newline so it executes) into the
        // interactive shell, matching the `cmux new-workspace --cwd` contract.
        #expect(args.initialTerminalInput == setup + "\n")
    }

    @Test("worktree path is the workspace working directory")
    func worktreePathIsWorkingDirectory() {
        let args = makeResult(setupCommand: "echo hi").workspaceSpawnArgs()

        #expect(args.workingDirectory == "/tmp/project/.cmux/worktrees/cmux-sidebar-123")
        #expect(args.inheritWorkingDirectory == false)
        #expect(args.title == "cmux-sidebar-123")
    }

    @Test("empty setup command yields no input and no command")
    func emptySetupCommandYieldsNeither() {
        let args = makeResult(setupCommand: "").workspaceSpawnArgs()

        #expect(args.initialTerminalCommand == nil)
        #expect(args.initialTerminalInput == nil)
    }
}
