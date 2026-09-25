import CmuxCore
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// https://github.com/manaflow-ai/cmux/issues/12813: what a workspace does
/// around a remote session that could never become ready. The issue's status
/// checks (`state=connecting`, `daemon.state=unavailable`,
/// `remote connection is not active`) came from these three paths.
@Suite(.serialized)
@MainActor
struct RemoteSessionParkedReconnectTests {
    @Test
    func reconnectStartsAReplacementAfterASessionThatNeverProvisionedTheRemote() async throws {
        // The first session never got a daemon, so it never wrote relay
        // metadata. Its transport cleanup then finds no slot file and the
        // ownership check exits 64: there is nothing of ours to clean, which
        // must not be read as a failed cleanup that blocks every reconnect.
        let runner = ParkedReconnectRecordingRunner(cleanupStatus: 64)
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        let configuration = Self.configuration()
        workspace.configureRemoteConnection(configuration, autoConnect: true)
        _ = try #require(await Self.nextBootstrapRequest(runner))
        // The session owner gave up; the sidebar now offers Reconnect.
        workspace.applyRemoteConnectionStateUpdate(
            .suspended,
            detail: "Remote daemon bootstrap failed. Use Reconnect to try again.",
            target: "cmux-macmini"
        )
        let requestsBeforeReconnect = runner.bootstrapRequestCount

        _ = workspace.reconnectRemoteConnection()
        _ = try #require(await Self.nextCleanupCommand(runner))
        _ = try #require(
            await Self.nextBootstrapRequest(runner),
            "Reconnect must start a replacement controller"
        )
        await workspace.remoteSessionTransitionTask?.value

        #expect(runner.bootstrapRequestCount > requestsBeforeReconnect)
        #expect(workspace.remoteSessionController != nil)
        #expect(workspace.remoteConnectionState != .error)

        workspace.disconnectRemoteConnection(clearConfiguration: true)
        await workspace.remoteSessionTransitionTask?.value
        workspace.teardownAllPanels()
    }

    @Test
    func aLaunchingAttachDoesNotRepaintAParkedSessionAsConnecting() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.configureRemoteConnection(Self.configuration(), autoConnect: false)
        let parkedDetail = "Remote daemon bootstrap failed. Use Reconnect to try again."
        workspace.applyRemoteConnectionStateUpdate(
            .suspended,
            detail: parkedDetail,
            target: "cmux-macmini"
        )

        // Every attach attempt of the terminal's wrapper registers itself
        // first. While the session owner is parked that registration is not
        // progress, and it must not erase the one actionable message.
        #expect(
            workspace.markRemoteTerminalSessionLaunching(
                surfaceId: panel.id,
                terminalLifecycleID: panel.surface.terminalLifecycleId,
                attemptID: UUID()
            )
        )

        #expect(workspace.remoteConnectionState == .suspended)
        #expect(workspace.remoteConnectionDetail == parkedDetail)
        workspace.teardownAllPanels()
    }

    @Test(.timeLimit(.minutes(1)))
    func aDeliberateDisconnectStopsWaitingAttachAndKeepsDisconnectedPresentation() async throws {
        let manager = TabManager()
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(nil) }
        let configuration = Self.configuration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to cmux-macmini via shared local proxy 127.0.0.1:64012",
            target: "cmux-macmini"
        )
        #expect(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: panel.id,
                relayPort: 64_012
            )
        )

        workspace.disconnectRemoteConnection(clearConfiguration: false)
        await workspace.remoteSessionTransitionTask?.value

        #expect(workspace.remoteSessionController == nil)
        #expect(workspace.remoteConnectionState == .disconnected)
        #expect(
            workspace.markRemoteTerminalSessionLaunching(
                surfaceId: panel.id,
                terminalLifecycleID: panel.surface.terminalLifecycleId,
                attemptID: UUID()
            )
        )
        #expect(workspace.remoteConnectionState == .disconnected)

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "workspace.remote.pty_bridge",
            "params": [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panel.id.uuidString,
                "session_id": "ssh-\(workspace.id.uuidString)-\(panel.id.uuidString)",
                "attachment_id": panel.id.uuidString,
                "require_existing": true,
                "wait_for_ready": true,
            ],
        ]
        let line = try #require(
            String(data: JSONSerialization.data(withJSONObject: request), encoding: .utf8)
        )
        let response = await Task.detached {
            TerminalController.shared.handleSocketLine(line)
        }.value
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
        let error = try #require(payload["error"] as? [String: Any])

        #expect(error["code"] as? String == "remote_session_parked")
        #expect((error["message"] as? String)?.isEmpty == false)
    }

    @Test
    func aParkedAttachExitKeepsPersistentPanesAndTheirSessionsForReconnect() async throws {
        let manager = TabManager()
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.configureRemoteConnection(Self.configuration(), autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to cmux-macmini via shared local proxy 127.0.0.1:64012",
            target: "cmux-macmini"
        )
        let sibling = try #require(workspace.newTerminalSplit(
            from: panel.id,
            orientation: .horizontal,
            focus: false
        ))
        let sessionID = "ssh-\(workspace.id.uuidString)-\(panel.id.uuidString)"
        workspace.remotePTYSessionIDsByPanelId[panel.id] = sessionID

        // The user disconnects and reconnects. The panes' attach wrappers keep
        // running across that, while the workspace tracks the panes as
        // disconnected placeholders rather than active remote terminals.
        workspace.disconnectRemoteConnection(clearConfiguration: false)
        await workspace.remoteSessionTransitionTask?.value
        try #require(workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
        let siblingIsRemote = workspace.remoteDisconnectPlaceholderPanelIds.contains(sibling.id)

        // The reconnect parks, so both wrappers receive the parked verdict
        // and exit. Their persistent remote PTYs are still running: the panes
        // must stay (showing the error) and stay bound to those sessions, or
        // Reconnect has nothing to reattach and the remote shells are orphaned.
        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: panel.id)
        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: sibling.id)

        #expect(workspace.terminalPanel(for: panel.id) != nil)
        if siblingIsRemote {
            #expect(workspace.terminalPanel(for: sibling.id) != nil)
        }
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
        #expect(workspace.remotePTYSessionIDsByPanelId[panel.id] == sessionID)
    }

    @Test(.timeLimit(.minutes(1)))
    func aWaitingAttachFailsAtOnceWhenTheWorkspaceCannotCreateAController() async throws {
        // A cleanup that genuinely failed leaves the workspace in `.error`
        // with no controller. Nothing will create one until the user
        // reconnects, so `pty_bridge wait_for_ready` must say so instead of
        // waiting out its controller deadline.
        let runner = ParkedReconnectRecordingRunner(cleanupStatus: 1)
        let manager = TabManager()
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(nil) }
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        let configuration = Self.configuration()
        workspace.configureRemoteConnection(configuration, autoConnect: true)
        _ = try #require(await Self.nextBootstrapRequest(runner))
        workspace.configureRemoteConnection(configuration, autoConnect: true)
        _ = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        try #require(workspace.remoteSessionController == nil)
        try #require(workspace.remoteConnectionState == .error)

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "workspace.remote.pty_bridge",
            "params": [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panel.id.uuidString,
                "session_id": "ssh-\(workspace.id.uuidString)-\(panel.id.uuidString)",
                "attachment_id": panel.id.uuidString,
                "require_existing": true,
                "wait_for_ready": true,
            ],
        ]
        let line = try #require(
            String(data: JSONSerialization.data(withJSONObject: request), encoding: .utf8)
        )
        let response = await Task.detached {
            TerminalController.shared.handleSocketLine(line)
        }.value

        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
        let error = try #require(payload["error"] as? [String: Any])
        // Waiting out the controller deadline answers `remote_pty_error`
        // ("remote connection is not active"), so this code proves it did not.
        #expect(error["code"] as? String == "remote_session_parked")
        #expect((error["message"] as? String)?.isEmpty == false)
    }

    private static func configuration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_012,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-parked-reconnect"
        )
    }

    private static func nextCleanupCommand(_ runner: ParkedReconnectRecordingRunner) async -> String? {
        await Task.detached { runner.waitForCleanupCommand() }.value
    }

    private static func nextBootstrapRequest(_ runner: ParkedReconnectRecordingRunner) async -> String? {
        await Task.detached { runner.waitForBootstrapRequest() }.value
    }
}
