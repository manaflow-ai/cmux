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

    @Test func reconnectWithholdsRootUntilAFreshPaneCwd() throws {
        let harness = try RemoteTmuxSessionMirrorLayoutHarness()
        defer { harness.tearDown() }
        harness.connection.handleMessageForTesting(
            .subscriptionChanged(name: "cmux_cwd_11", value: "/home/dev/project")
        )
        #expect(sshRoot(harness.workspace)?.path == "/home/dev/project")
        #expect(sshRoot(harness.workspace)?.available == true)

        harness.connection.beginReconnecting()
        #expect(sshRoot(harness.workspace)?.path == nil)
        #expect(sshRoot(harness.workspace)?.available == false)
        #expect(harness.windowMirror?.cwdByPaneId[11] == nil)

        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting, label: "files-root-reconnect-test",
            maxPendingBytes: 1 << 16, onFailure: {}
        )
        defer {
            writer.close()
            try? pipe.fileHandleForReading.close()
        }
        harness.connection.installStdinWriterForTesting(writer)
        harness.connection.handleMessageForTesting(.enter)
        harness.connection.reseedAfterReconnect()
        var queriedPaths: [Int] = []
        var commandNumber = 1
        while let kind = harness.connection.pendingCommandKindsForTesting.first, commandNumber < 200 {
            let lines: [String]
            switch kind {
            case let .panePath(paneId):
                queriedPaths.append(paneId)
                lines = ["/home/dev/moved"]
            default:
                lines = []
            }
            harness.connection.handleMessageForTesting(
                .commandResult(commandNumber: commandNumber, lines: lines, isError: false)
            )
            commandNumber += 1
        }
        #expect(queriedPaths == [11])
        #expect(sshRoot(harness.workspace)?.path == "/home/dev/moved")
        #expect(sshRoot(harness.workspace)?.available == true)
    }

    @Test func activePaneWithoutCwdWithholdsThePreviousPaneDirectory() throws {
        let harness = try RemoteTmuxSessionMirrorLayoutHarness()
        defer { harness.tearDown() }
        try harness.publishLayout(
            "abcd,80x24,0,0[80x12,0,0,11,80x11,0,13,22]",
            rects: ["%11 0 0 80 12 1 off :zsh", "%22 0 13 80 11 0 off :zsh"]
        )
        harness.connection.handleMessageForTesting(
            .subscriptionChanged(name: "cmux_cwd_11", value: "/home/dev/first")
        )
        #expect(sshRoot(harness.workspace)?.path == "/home/dev/first")

        harness.connection.handleMessageForTesting(.windowPaneChanged(windowId: 1, paneId: 22))
        #expect(sshRoot(harness.workspace) != nil)
        #expect(sshRoot(harness.workspace)?.path == nil)

        harness.connection.handleMessageForTesting(
            .subscriptionChanged(name: "cmux_cwd_22", value: "/home/dev/second")
        )
        #expect(sshRoot(harness.workspace)?.path == "/home/dev/second")
    }

    private func sshRoot(_ workspace: Workspace) -> (path: String?, available: Bool)? {
        guard case let .remoteSSH(_, _, _, path, available, _) =
                FileExplorerWorkspaceRootResolver().resolve(workspace) else { return nil }
        return (path, available)
    }

    @Test(.timeLimit(.minutes(1))) func observationFollowsDirectoryAndConnectionChanges() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let (applied, sink) = AsyncStream<FileExplorerWorkspaceRoot>.makeStream()
        var roots = applied.makeAsyncIterator()
        let observation = FileExplorerWorkspaceObservation(
            workspace: fixture.workspace, resolver: FileExplorerWorkspaceRootResolver(),
            apply: { sink.yield($0) }
        )
        defer { observation.stop() }
        observation.refresh()
        guard case let .remoteSSH(_, _, _, _, initiallyAvailable, _) = await roots.next() else {
            Issue.record("A connecting mirror must publish its SSH root")
            return
        }
        #expect(!initiallyAvailable)

        fixture.connection.handleMessageForTesting(.enter)
        guard case let .remoteSSH(_, _, _, _, available, _) = await roots.next() else {
            Issue.record("Connecting the mirror must publish its SSH root")
            return
        }
        #expect(available)

        let panelID = try #require(fixture.workspace.focusedPanelId)
        fixture.workspace.updateRemotePanelDirectoryWithMetadata(
            panelId: panelID, directory: "/home/dev/first"
        )
        guard case let .remoteSSH(_, _, _, firstPath, _, _) = await roots.next() else {
            Issue.record("Directory reports must retain the SSH root")
            return
        }
        #expect(firstPath == "/home/dev/first")
        fixture.workspace.updateRemotePanelDirectoryWithMetadata(
            panelId: panelID, directory: "/home/dev/second"
        )
        guard case let .remoteSSH(_, _, _, path, _, _) = await roots.next() else {
            Issue.record("Directory reports must retain the SSH root")
            return
        }
        #expect(path == "/home/dev/second")

        fixture.connection.stop()
        guard case let .remoteSSH(_, _, _, _, connected, _) = await roots.next() else {
            Issue.record("A disconnected mirror must retain an unavailable SSH root")
            return
        }
        #expect(!connected)
        fixture.mirror.detachObserver()
        #expect(await roots.next() == FileExplorerWorkspaceRoot.none)
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
