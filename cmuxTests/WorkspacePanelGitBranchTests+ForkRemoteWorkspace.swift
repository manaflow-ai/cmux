import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Fork in remote workspaces
extension WorkspacePanelGitBranchTests {
    func testForkAgentConversationInRemoteWorkspaceUsesRemoteStartupCommand() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-fork",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-fork-remote.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        let initialRemoteSessionCount = workspace.activeRemoteTerminalSessionCount
        XCTAssertEqual(initialRemoteSessionCount, 1)
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversation(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                direction: .right
            )
        )

        XCTAssertEqual(forkPanel.surface.debugInitialCommand(), "ssh cmux-macmini")
        XCTAssertNil(forkPanel.requestedWorkingDirectory)
        XCTAssertEqual(workspace.panelDirectories[forkPanel.id], "/Users/cmux/project")
        XCTAssertEqual(forkPanel.surface.initialInput, snapshot.forkCommand.map { $0 + "\n" })
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, initialRemoteSessionCount + 1)
    }

    func testForkAgentConversationInRemoteWorkspaceUsesFallbackDirectoryInForkCommand() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-fork-fallback",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-fork-fallback-remote.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        workspace.currentDirectory = "/Users/cmux/fallback repo"
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversation(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                direction: .right
            )
        )

        XCTAssertEqual(forkPanel.surface.debugInitialCommand(), "ssh cmux-macmini")
        XCTAssertNil(forkPanel.requestedWorkingDirectory)
        XCTAssertEqual(workspace.panelDirectories[forkPanel.id], "/Users/cmux/fallback repo")
        XCTAssertEqual(
            forkPanel.surface.initialInput,
            "{ cd -- '/Users/cmux/fallback repo' 2>/dev/null || [ ! -d '/Users/cmux/fallback repo' ]; } && '/Users/example/.bun/bin/codex' 'fork' '019dad34-d218-7943-b81a-eddac5c87951'\n"
        )
    }

    func testSessionIndexRemoteSplitDoesNotInjectRemoteStartupCommand() throws {
        let fileManager = FileManager.default
        let hookStateRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-session-drop-hook-state-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: hookStateRoot, withIntermediateDirectories: true)
        let previousHookStateDir = getenv("CMUX_AGENT_HOOK_STATE_DIR").map { String(cString: $0) }
        setenv("CMUX_AGENT_HOOK_STATE_DIR", hookStateRoot.path, 1)
        defer {
            if let previousHookStateDir {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDir, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
            try? fileManager.removeItem(at: hookStateRoot)
        }

        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-session-drop",
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-session-drop-remote.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        let initialRemoteSessionCount = workspace.activeRemoteTerminalSessionCount
        XCTAssertEqual(initialRemoteSessionCount, 1)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let initialInput = "codex resume session-drop\n"

        let splitPanel = try XCTUnwrap(
            workspace.splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: .horizontal,
                insertFirst: false,
                workingDirectory: "/Users/cmux/project",
                initialInput: initialInput
            )
        )

        XCTAssertNil(splitPanel.surface.debugInitialCommand())
        XCTAssertEqual(splitPanel.surface.initialInput, initialInput)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, initialRemoteSessionCount)
    }

    func testForkAgentWorkspaceLaunchInRemoteWorkspacePreservesRemoteContext() throws {
        let workspace = Workspace()
        let agentSocketPath = "/tmp/cmux-fork-agent.sock"
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: 2222,
                identityFile: "/Users/example/.ssh/cmux",
                sshOptions: ["ServerAliveInterval=30", "ForwardAgent=yes"],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-fork",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-fork-remote.sock",
                terminalStartupCommand: "ssh -p 2222 -i /Users/example/.ssh/cmux -o ServerAliveInterval=30 -o ForwardAgent=yes -tt cmux-macmini",
                agentSocketPath: agentSocketPath
            ),
            autoConnect: false
        )
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let launch = try XCTUnwrap(
            workspace.forkAgentWorkspaceLaunch(
                fromPanelId: sourcePanelId,
                snapshot: snapshot
            )
        )

        XCTAssertEqual(launch.workingDirectory, "/Users/cmux/project")
        XCTAssertNil(launch.terminalWorkingDirectory)
        XCTAssertEqual(
            launch.initialTerminalCommand,
            "ssh -p 2222 -i /Users/example/.ssh/cmux -o ServerAliveInterval=30 -o ForwardAgent=yes -tt cmux-macmini"
        )
        XCTAssertEqual(launch.initialTerminalInput, snapshot.forkCommand.map { $0 + "\n" })
        XCTAssertEqual(launch.initialTerminalEnvironment["SSH_AUTH_SOCK"], agentSocketPath)
        XCTAssertTrue(launch.autoConnectRemoteConfiguration)
        XCTAssertEqual(launch.remoteConfiguration?.destination, "cmux-macmini")
        XCTAssertEqual(launch.remoteConfiguration?.port, 2222)
        XCTAssertEqual(launch.remoteConfiguration?.identityFile, "/Users/example/.ssh/cmux")
        XCTAssertEqual(launch.remoteConfiguration?.sshOptions, ["ServerAliveInterval=30", "ForwardAgent=yes"])
        XCTAssertEqual(launch.remoteConfiguration?.agentSocketPath, agentSocketPath)
        XCTAssertEqual(launch.remoteConfiguration?.sshTerminalStartupEnvironment?["SSH_AUTH_SOCK"], agentSocketPath)
        XCTAssertEqual(launch.remoteConfiguration?.sshProcessEnvironment?["SSH_AUTH_SOCK"], agentSocketPath)
        XCTAssertNil(launch.remoteConfiguration?.relayPort)
        XCTAssertNil(launch.remoteConfiguration?.localSocketPath)
    }

    func testForkAgentWorkspaceLaunchFromPersistentSSHPTYDoesNotReuseParentRelayOrDaemonSlot() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: 2222,
                identityFile: "/Users/example/.ssh/cmux",
                sshOptions: ["ControlMaster=auto", "ControlPersist=600"],
                localProxyPort: nil,
                relayPort: 64017,
                relayID: "relay-fork-persistent",
                relayToken: String(repeating: "c", count: 64),
                localSocketPath: "/tmp/cmux-fork-persistent.sock",
                terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "ssh-parent-slot"
            ),
            autoConnect: false
        )
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let launch = try XCTUnwrap(
            workspace.forkAgentWorkspaceLaunch(
                fromPanelId: sourcePanelId,
                snapshot: snapshot
            )
        )

        XCTAssertTrue(launch.autoConnectRemoteConfiguration)
        XCTAssertEqual(launch.remoteConfiguration?.destination, "cmux-macmini")
        XCTAssertEqual(launch.remoteConfiguration?.port, 2222)
        XCTAssertEqual(launch.remoteConfiguration?.preserveAfterTerminalExit, false)
        XCTAssertNil(launch.remoteConfiguration?.relayPort)
        XCTAssertNil(launch.remoteConfiguration?.relayID)
        XCTAssertNil(launch.remoteConfiguration?.relayToken)
        XCTAssertNil(launch.remoteConfiguration?.localSocketPath)
        XCTAssertNil(launch.remoteConfiguration?.persistentDaemonSlot)
        let startupCommand = try XCTUnwrap(launch.remoteConfiguration?.terminalStartupCommand)
        XCTAssertFalse(startupCommand.contains("ssh-pty-attach"), startupCommand)
        XCTAssertEqual(
            startupCommand,
            "ssh -p 2222 -i /Users/example/.ssh/cmux -tt cmux-macmini"
        )
    }

    func testForkAgentWorkspaceLaunchInRemoteWorkspaceUsesFallbackDirectoryInForkCommand() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-workspace-fallback",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-workspace-fallback-remote.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        workspace.currentDirectory = "/Users/cmux/fallback repo"
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let launch = try XCTUnwrap(
            workspace.forkAgentWorkspaceLaunch(
                fromPanelId: sourcePanelId,
                snapshot: snapshot
            )
        )

        XCTAssertEqual(launch.workingDirectory, "/Users/cmux/fallback repo")
        XCTAssertNil(launch.terminalWorkingDirectory)
        XCTAssertEqual(launch.initialTerminalCommand, "ssh -tt cmux-macmini")
        XCTAssertEqual(
            launch.initialTerminalInput,
            "{ cd -- '/Users/cmux/fallback repo' 2>/dev/null || [ ! -d '/Users/cmux/fallback repo' ]; } && '/Users/example/.bun/bin/codex' 'fork' '019dad34-d218-7943-b81a-eddac5c87951'\n"
        )
    }

    func testForkAgentWorkspaceLaunchInLocalWorkspaceUsesLocalTerminalWorkingDirectory() throws {
        let workspace = Workspace()
        workspace.currentDirectory = "/tmp/local fork repo"
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let launch = try XCTUnwrap(
            workspace.forkAgentWorkspaceLaunch(
                fromPanelId: sourcePanelId,
                snapshot: snapshot
            )
        )

        XCTAssertEqual(launch.workingDirectory, "/tmp/local fork repo")
        XCTAssertEqual(launch.terminalWorkingDirectory, "/tmp/local fork repo")
        XCTAssertNil(launch.initialTerminalCommand)
        XCTAssertFalse(launch.autoConnectRemoteConfiguration)
        XCTAssertNil(launch.remoteConfiguration)
        XCTAssertEqual(
            launch.initialTerminalInput,
            "{ cd -- '/tmp/local fork repo' 2>/dev/null || [ ! -d '/tmp/local fork repo' ]; } && '/Users/example/.bun/bin/codex' 'fork' '019dad34-d218-7943-b81a-eddac5c87951'\n"
        )
    }

    func testForkAgentConversationInRemoteConfiguredLocalWorkspaceAllowsLauncherScript() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                transport: .websocket,
                destination: "cloud-vm",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: 54321,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: nil
            ),
            autoConnect: false
        )
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let longPath = "/Users/cmux/" + String(repeating: "nested-project-", count: 120)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    longPath
                ],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertGreaterThan(
            (snapshot.forkCommand.map { $0 + "\n" } ?? "").utf8.count,
            SessionRestorableAgentSnapshot.maxInlineStartupInputBytes
        )
        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversation(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                direction: .right
            )
        )
        XCTAssertNil(forkPanel.surface.debugInitialCommand())
        XCTAssertEqual(forkPanel.requestedWorkingDirectory, "/Users/cmux/project")
        XCTAssertTrue(forkPanel.surface.initialInput?.hasPrefix("/bin/zsh ") == true)

        let launch = try XCTUnwrap(
            workspace.forkAgentWorkspaceLaunch(
                fromPanelId: sourcePanelId,
                snapshot: snapshot
            )
        )
        XCTAssertEqual(launch.terminalWorkingDirectory, "/Users/cmux/project")
        XCTAssertNil(launch.initialTerminalCommand)
        XCTAssertFalse(launch.autoConnectRemoteConfiguration)
        XCTAssertNil(launch.remoteConfiguration)
        XCTAssertTrue(launch.initialTerminalInput.hasPrefix("/bin/zsh "))
    }

    func testForkAgentConversationFromLocalTerminalInRemoteWorkspaceStaysLocal() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-fork-local",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-fork-local-remote.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        let initialRemoteSessionCount = workspace.activeRemoteTerminalSessionCount
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let localPanel = try XCTUnwrap(
            workspace.splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: .horizontal,
                insertFirst: false,
                workingDirectory: "/tmp/local project",
                initialInput: nil
            )
        )
        let longPath = "/tmp/local/" + String(repeating: "nested-project-", count: 120)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/tmp/local project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    longPath
                ],
                workingDirectory: "/tmp/local project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversation(
                fromPanelId: localPanel.id,
                snapshot: snapshot,
                direction: .right
            )
        )
        XCTAssertNil(forkPanel.surface.debugInitialCommand())
        XCTAssertEqual(forkPanel.requestedWorkingDirectory, "/tmp/local project")
        XCTAssertTrue(forkPanel.surface.initialInput?.hasPrefix("/bin/zsh ") == true)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, initialRemoteSessionCount)

        let launch = try XCTUnwrap(
            workspace.forkAgentWorkspaceLaunch(
                fromPanelId: localPanel.id,
                snapshot: snapshot
            )
        )
        XCTAssertEqual(launch.terminalWorkingDirectory, "/tmp/local project")
        XCTAssertNil(launch.initialTerminalCommand)
        XCTAssertFalse(launch.autoConnectRemoteConfiguration)
        XCTAssertNil(launch.remoteConfiguration)
        XCTAssertTrue(launch.initialTerminalInput.hasPrefix("/bin/zsh "))
    }

    func testForkAgentConversationInRemoteWorkspaceRejectsLocalLauncherScriptFallback() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64000,
                relayID: "relay-fork",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-fork-remote.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let longPath = "/Users/cmux/" + String(repeating: "nested-project-", count: 120)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/Users/cmux/project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--model",
                    "gpt-5.4",
                    "--add-dir",
                    longPath
                ],
                workingDirectory: "/Users/cmux/project",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertGreaterThan(
            (snapshot.forkCommand.map { $0 + "\n" } ?? "").utf8.count,
            SessionRestorableAgentSnapshot.maxInlineStartupInputBytes
        )
        XCTAssertNil(snapshot.forkStartupInput(allowLauncherScript: false))
        XCTAssertNil(
            workspace.forkAgentConversation(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                direction: .right
            )
        )
        XCTAssertNil(
            workspace.forkAgentWorkspaceLaunch(
                fromPanelId: sourcePanelId,
                snapshot: snapshot
            )
        )
    }

}
