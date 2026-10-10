import AppKit
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

@MainActor
@Suite("Plain SSH Files root")
struct PlainSSHFileExplorerRootTests {
    @Test("A detected SSH session uses the selected terminal's remote cwd")
    func detectedSSHSessionUsesRemoteCwd() throws {
        let workspace = Workspace()
        let session = Self.session(destination: "deploy@build-host")
        let resolver = FileExplorerWorkspaceRootResolver()

        let root = resolver.resolve(
            workspace,
            detectedSSHSession: session,
            detectedRemoteWorkingDirectory: "~/project"
        )

        guard case let .remoteSSH(workspaceId, connection, displayTarget, rootPath, isAvailable, detail) = root else {
            Issue.record("Expected a detected plain SSH root")
            return
        }
        #expect(workspaceId == workspace.id)
        #expect(connection.destination == session.destination)
        #expect(displayTarget == session.destination)
        #expect(rootPath == "~/project")
        #expect(isAvailable)
        #expect(detail == nil)
    }

    @Test("Clearing detection restores the local workspace root")
    func clearingDetectionRestoresLocalRoot() throws {
        let workspace = Workspace(workingDirectory: "/Users/test/project")
        let resolver = FileExplorerWorkspaceRootResolver()
        let detected = resolver.resolve(
            workspace,
            detectedSSHSession: Self.session(destination: "deploy@build-host"),
            detectedRemoteWorkingDirectory: "/srv/project"
        )
        let restored = resolver.resolve(
            workspace,
            detectedSSHSession: nil,
            detectedRemoteWorkingDirectory: nil
        )

        guard case .remoteSSH = detected else {
            Issue.record("Expected the precondition to be remote")
            return
        }
        guard case let .local(workspaceId, path) = restored else {
            Issue.record("Expected local restoration after SSH exit")
            return
        }
        #expect(workspaceId == workspace.id)
        #expect(path == "/Users/test/project")
    }

    @Test("Remote shell titles provide safe absolute or home-relative cwds")
    func remoteShellTitleProvidesRemoteCwd() {
        #expect(
            TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "deploy@build-host:~/project")
                == "~/project"
        )
        #expect(
            TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "deploy@build-host:22:/srv/project")
                == "/srv/project"
        )
        #expect(
            TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "deploy@[2001:db8::1]:/srv/project")
                == "/srv/project"
        )
        #expect(
            TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "build-host:~/project") == nil
        )
        #expect(
            TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: "deploy@build-host:project") == nil
        )
    }

    @Test("SSH detection snapshots are scoped to the active terminal")
    func detectionSnapshotsFollowTerminalSelection() async throws {
        let first = Self.session(destination: "first@example.com")
        let second = Self.session(destination: "second@example.com")
        let monitor = FileExplorerSSHSessionMonitor { ttyName in
            ttyName == "ttys001" ? first : second
        }
        var updates = await monitor.updates().makeAsyncIterator()
        #expect((await updates.next()).flatMap { $0 } == nil)

        await monitor.update(
            isEnabled: true,
            workspaceId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
            panelId: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            ttyName: "/dev/ttys001"
        )
        let firstSnapshot = try #require(await updates.next() ?? nil)
        #expect(firstSnapshot.ttyName == "ttys001")
        #expect(firstSnapshot.session == first)

        await monitor.update(
            isEnabled: true,
            workspaceId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
            panelId: UUID(uuidString: "22222222-2222-2222-2222-222222222222"),
            ttyName: "/dev/ttys002"
        )
        let secondSnapshot = try #require(await updates.next() ?? nil)
        #expect(secondSnapshot.panelId == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(secondSnapshot.session == second)

        await monitor.update(isEnabled: false, workspaceId: nil, panelId: nil, ttyName: nil)
        #expect((await updates.next()).flatMap { $0 } == nil)
        await monitor.stop()
    }

    private static func session(destination: String) -> DetectedSSHSession {
        DetectedSSHSession(
            destination: destination,
            port: 22,
            identityFile: "/Users/test/.ssh/id_ed25519",
            configFile: "/Users/test/.ssh/config",
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )
    }
}
