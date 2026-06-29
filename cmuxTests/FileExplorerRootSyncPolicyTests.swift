import AppKit
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("File explorer root sync policy")
struct FileExplorerRootSyncPolicyTests {
    @Test("Hidden right sidebar keeps file explorer root lazy")
    func hiddenRightSidebarKeepsFileExplorerRootLazy() {
        for mode in RightSidebarMode.allCases {
            #expect(
                FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
                    isRightSidebarVisible: false,
                    mode: mode
                ) == false
            )
        }
    }

    @Test("Visible Files and Find may sync file explorer root")
    func visibleFileModesMaySyncFileExplorerRoot() {
        for mode in [RightSidebarMode.files, .find] {
            #expect(
                FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
                    isRightSidebarVisible: true,
                    mode: mode
                )
            )
        }
    }

    @Test("Visible non-file modes keep file explorer root lazy")
    func visibleNonFileModesKeepFileExplorerRootLazy() {
        let fileModes = Set([RightSidebarMode.files, .find])
        for mode in RightSidebarMode.allCases.filter({ !fileModes.contains($0) }) {
            #expect(
                FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
                    isRightSidebarVisible: true,
                    mode: mode
                ) == false
            )
        }
    }
}

@MainActor
@Suite("Right sidebar keyboard navigation")
struct RightSidebarKeyboardNavigationTests {
    @Test("Return and keypad Enter open the selected item")
    func returnAndKeypadEnterOpenSelection() throws {
        for keyCode in [UInt16(36), UInt16(76)] {
            let event = try #require(Self.keyEvent(keyCode: keyCode, modifierFlags: []))
            #expect(event.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
        }
    }

    @Test("Command Down opens the selected item")
    func commandDownOpensSelection() throws {
        let event = try #require(Self.keyEvent(keyCode: 125, modifierFlags: [.command]))
        #expect(event.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
    }

    @Test("Plain Down, Shift Return, and Command Return keep their existing routes")
    func nonActivationKeysDoNotOpenSelection() throws {
        let plainDown = try #require(Self.keyEvent(keyCode: 125, modifierFlags: []))
        let shiftReturn = try #require(Self.keyEvent(keyCode: 36, modifierFlags: [.shift]))
        let commandReturn = try #require(Self.keyEvent(keyCode: 36, modifierFlags: [.command]))

        #expect(!plainDown.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
        #expect(!shiftReturn.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
        #expect(!commandReturn.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
    }

    private static func keyEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }
}

/// Regression coverage for
/// https://github.com/manaflow-ai/cmux/issues/5471: the Files sidebar tree must
/// re-root when the shell `cd`s inside a `cmux ssh` (remote SSH workspace)
/// session. The remote shell reports its cwd over the relay
/// (`surface.report_pwd`), which updates the focused remote terminal's workspace
/// `currentDirectory`; the file-explorer root is derived from that value, so the
/// tree follows the remote cwd.
@MainActor
@Suite("Right sidebar file tree remote SSH root")
struct RightSidebarFileTreeRemoteRootTests {
    @Test("Remote SSH file tree root follows the focused terminal's reported cwd")
    func remoteSSHFileTreeRootFollowsReportedWorkingDirectory() throws {
        let workspace = Workspace()
        let configuration = WorkspaceRemoteConfiguration(
            destination: "deploy@cmux-host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64071,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh deploy@cmux-host"
        )

        workspace.configureRemoteConnection(configuration, autoConnect: false)
        #expect(workspace.isRemoteWorkspace)

        let panelID = try #require(workspace.focusedTerminalPanel?.id)
        #expect(workspace.isRemoteTerminalSurface(panelID))

        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: nil,
            target: "deploy@cmux-host"
        )

        // Initial cwd reported by the remote shell integration on first prompt.
        #expect(workspace.updatePanelDirectory(panelId: panelID, directory: "/home/deploy"))
        #expect(workspace.currentDirectory == "/home/deploy")
        #expect(
            Self.remoteRootPath(RightSidebarToolPanel.fileExplorerWorkspaceRoot(for: workspace))
                == "/home/deploy"
        )

        // `cd /home/deploy/project` inside the SSH session — the tree must follow.
        #expect(workspace.updatePanelDirectory(panelId: panelID, directory: "/home/deploy/project"))
        #expect(workspace.currentDirectory == "/home/deploy/project")

        let root = RightSidebarToolPanel.fileExplorerWorkspaceRoot(for: workspace)
        #expect(Self.remoteRootPath(root) == "/home/deploy/project")
        #expect(Self.isRemoteAvailable(root))

        // Tear down the remote session so the test leaves no live connection
        // state behind, matching the other WorkspaceRemoteConnectionTests.
        workspace.markRemoteTerminalSessionEnded(surfaceId: panelID, relayPort: 64071)
    }

    private static func remoteRootPath(_ root: FileExplorerWorkspaceRoot) -> String? {
        guard case let .remoteSSH(_, _, _, rootPath, _, _) = root else { return nil }
        return rootPath
    }

    private static func isRemoteAvailable(_ root: FileExplorerWorkspaceRoot) -> Bool {
        guard case let .remoteSSH(_, _, _, _, isAvailable, _) = root else { return false }
        return isAvailable
    }
}
