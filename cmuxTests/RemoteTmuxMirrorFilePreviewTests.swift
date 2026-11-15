import CmuxCore
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cmd+clicking a file path in a `cmux ssh-tmux` mirror pane opens the remote
/// file preview, read over the mirror's own SSH ControlMaster
/// (https://github.com/manaflow-ai/cmux/issues/15749).
@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorFilePreviewTests {
    @MainActor
    private struct Harness {
        let host: RemoteTmuxHost
        let manager: TabManager
        let workspace: Workspace
        let connection: RemoteTmuxControlConnection
        let sessionMirror: RemoteTmuxSessionMirror
        let windowMirror: RemoteTmuxWindowMirror
        let pane: TerminalPanel

        init(host: RemoteTmuxHost = RemoteTmuxHost(
            destination: "me@devbox",
            port: 2222,
            identityFile: "/tmp/id_test"
        )) throws {
            self.host = host
            manager = TabManager()
            workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
            workspace.isRemoteTmuxMirror = true
            connection = RemoteTmuxControlConnection(host: host, sessionName: "work")
            connection.windowsByID[1] = RemoteTmuxWindow(
                id: 1, name: "main", width: 80, height: 24,
                layout: RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(4))
            )
            connection.windowOrder = [1]
            connection.activePaneByWindow[1] = 4
            connection.publishedWindowIdByPane = [4: 1]
            sessionMirror = RemoteTmuxSessionMirror(
                host: host,
                sessionName: "work",
                connection: connection,
                tabManager: manager,
                workspace: workspace
            )
            windowMirror = try #require(sessionMirror.windowMirrorByWindowId[1])
            pane = try #require(windowMirror.panel(forPane: 4))
        }

        func tearDown() { sessionMirror.detachObserver() }
    }

    @Test func mirrorPaneReadsFilesOverTheMirrorsControlMaster() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let route = try #require(harness.workspace.remoteTerminalFilePreviewRoute(for: harness.pane.id))

        #expect(route.destination == "me@devbox")
        #expect(route.port == 2222)
        #expect(route.identityFile == "/tmp/id_test")
        #expect(route.displayTarget == "me@devbox:2222")
        // The mirror's socket, plus a ProxyCommand that fails if no master
        // answers on it. The file transport adds ControlMaster=no and
        // BatchMode=yes, so a click rides the live master or fails closed.
        #expect(route.sshOptions == [
            "ControlPath=\(harness.host.controlSocketPath)",
            "ProxyCommand=/usr/bin/false",
        ])
        let arguments = ProcessSSHFileExplorerTransport.sshArguments(
            connection: SSHFileExplorerConnection(
                destination: route.destination,
                port: route.port,
                identityFile: route.identityFile,
                sshOptions: route.sshOptions
            ),
            command: "true"
        )
        #expect(arguments.contains("ControlPath=\(harness.host.controlSocketPath)"))
        #expect(arguments.contains("ControlMaster=no"))
        #expect(arguments.contains("BatchMode=yes"))
        // A config ProxyJump or ProxyCommand can't take over, since OpenSSH
        // keeps the first value and command-line options come first.
        #expect(arguments.contains("ProxyCommand=/usr/bin/false"))
    }

    @Test func mirrorPaneResolvesToItsPanelAndOpensBesideItsWindowTab() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        #expect(harness.workspace.terminalLinkIsRemoteTerminal(harness.pane.id))
        #expect(harness.workspace.remoteFilePreviewSourcePanel(for: harness.pane.id) === harness.pane)
        // The pane isn't in the workspace's split tree, so the preview splits
        // beside the tmux window's tab instead.
        #expect(harness.workspace.remoteFilePreviewAnchorPanelID(for: harness.pane.id)
            == harness.windowMirror.panelId)
    }

    @Test func windowContainerIsNotAPreviewSource() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        // The container names the window, not a pane, so it has no working
        // directory to resolve a path against.
        #expect(harness.workspace.remoteTerminalFilePreviewRoute(for: harness.windowMirror.panelId) == nil)
    }

    @Test func endedMirrorHasNoRoute() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.connection.stop()

        #expect(harness.connection.exited)
        #expect(harness.workspace.remoteTerminalFilePreviewRoute(for: harness.pane.id) == nil)
    }

    @Test func brokeredHostHasNoRoute() throws {
        let harness = try Harness(host: RemoteTmuxHost(
            destination: "me@devbox",
            transportBroker: RemoteTmuxTransportBroker(executable: "/usr/local/bin/broker")
        ))
        defer { harness.tearDown() }

        // A plain ssh to the destination can't follow a broker's route.
        #expect(harness.workspace.remoteTerminalFilePreviewRoute(for: harness.pane.id) == nil)
    }

    @Test func localWorkspaceHasNoRoute() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let panelID = try #require(workspace.focusedPanelId)

        #expect(workspace.remoteTerminalFilePreviewRoute(for: panelID) == nil)
        #expect(workspace.remoteFilePreviewAnchorPanelID(for: panelID) == panelID)
    }
}
