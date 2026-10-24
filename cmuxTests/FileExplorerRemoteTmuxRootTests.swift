import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct FileExplorerRemoteTmuxRootTests {
    @Test func mirrorResolvesSSHRootWithoutManagedRemoteConfiguration() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let panelID = try #require(fixture.workspace.focusedPanelId)
        fixture.workspace.updateRemotePanelDirectoryWithMetadata(
            panelId: panelID, directory: "/home/dev/project"
        )
        fixture.connection.handleMessageForTesting(.enter)

        let root = FileExplorerWorkspaceRootResolver().resolve(fixture.workspace)
        guard case let .remoteSSH(workspaceID, connection, target, path, available, _) = root else {
            Issue.record("A tmux mirror must resolve an SSH root, got \(root)")
            return
        }
        #expect(fixture.workspace.remoteConfiguration == nil)
        #expect(workspaceID == fixture.workspace.id)
        #expect(connection.destination == fixture.host.destination)
        #expect(connection.port == 2222)
        #expect(connection.identityFile == "/tmp/cmux-fixture-key")
        #expect(target == fixture.host.destination)
        #expect(path == "/home/dev/project")
        #expect(available)
        let arguments = ProcessSSHFileExplorerTransport.sshArguments(
            connection: connection, command: "pwd"
        )
        #expect(arguments.contains("ControlPath=\(fixture.host.controlSocketPath)"))
        #expect(arguments.contains("ControlMaster=no"))
    }

    @Test func unreportedMirrorDirectoryNeverUsesLocalFallback() {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        fixture.workspace.currentDirectory = "/Users/local/should-not-be-remote"
        guard case let .remoteSSH(_, _, _, path, available, _) =
                FileExplorerWorkspaceRootResolver().resolve(fixture.workspace) else {
            Issue.record("A connecting mirror must keep its SSH root")
            return
        }
        #expect(path == nil)
        #expect(!available)
    }

    @Test func missingMirrorOwnerNeverResolvesLocalFiles() {
        let fixture = Fixture()
        fixture.mirror.detachObserver()
        defer { fixture.tearDown() }
        #expect(FileExplorerWorkspaceRootResolver().resolve(fixture.workspace) == .none)
    }

    @Test func nonSSHMirrorDoesNotClaimSSHAvailability() {
        let fixture = Fixture(transport: .et)
        defer { fixture.tearDown() }
        fixture.connection.handleMessageForTesting(.enter)
        #expect(FileExplorerWorkspaceRootResolver().resolve(fixture.workspace) == .none)
    }

    @Test func observationFollowsDirectoryAndConnectionChanges() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        var roots: [FileExplorerWorkspaceRoot] = []
        let observation = FileExplorerWorkspaceObservation(
            workspace: fixture.workspace, resolver: FileExplorerWorkspaceRootResolver(),
            apply: { roots.append($0) }
        )
        defer { observation.stop() }
        observation.refresh()
        #expect(roots.count == 1)

        fixture.connection.handleMessageForTesting(.enter)
        guard case let .remoteSSH(_, _, _, _, available, _) = roots.last else {
            Issue.record("Connecting the mirror must publish its SSH root")
            return
        }
        #expect(available)

        let panelID = try #require(fixture.workspace.focusedPanelId)
        fixture.workspace.updateRemotePanelDirectoryWithMetadata(
            panelId: panelID, directory: "/home/dev/first"
        )
        fixture.workspace.updateRemotePanelDirectoryWithMetadata(
            panelId: panelID, directory: "/home/dev/second"
        )
        guard case let .remoteSSH(_, _, _, path, _, _) = roots.last else {
            Issue.record("Directory reports must retain the SSH root")
            return
        }
        #expect(path == "/home/dev/second")

        fixture.connection.stop()
        guard case let .remoteSSH(_, _, _, _, connected, _) = roots.last else {
            Issue.record("A disconnected mirror must retain an unavailable SSH root")
            return
        }
        #expect(!connected)
        fixture.mirror.detachObserver()
        #expect(roots.last == FileExplorerWorkspaceRoot.none)
    }

    @MainActor
    private struct Fixture {
        let manager: TabManager
        let workspace: Workspace
        let host: RemoteTmuxHost
        let connection: RemoteTmuxControlConnection
        let mirror: RemoteTmuxSessionMirror

        init(transport: RemoteTmuxTransportKind = .ssh) {
            manager = TabManager()
            workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
            workspace.isRemoteTmuxMirror = true
            host = RemoteTmuxHost(
                destination: "dev@fixture.invalid", port: 2222,
                identityFile: "/tmp/cmux-fixture-key", transport: transport
            )
            connection = RemoteTmuxControlConnection(host: host, sessionName: "work")
            mirror = RemoteTmuxSessionMirror(
                host: host, sessionName: "work", connection: connection,
                tabManager: manager, workspace: workspace
            )
        }

        func tearDown() {
            mirror.detachObserver()
            connection.stop()
        }
    }
}
