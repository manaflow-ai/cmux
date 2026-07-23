import Testing
import Foundation
import Bonsplit
import CmuxCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct RemoteShimSurfaceRoutingTests {
    // Helper: build a workspace with a remote configuration and one tracked
    // remote terminal panel. Follow the construction pattern used by the
    // nearest existing Workspace unit test (grep: "remoteConfiguration ="
    // in cmuxTests/ and Packages/*/Tests for a factory/stub; reuse it).

    private func makeRemoteWorkspaceWithTrackedPanel() throws -> Workspace {
        let workspace = Workspace()
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-test-remote",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh cmux-test-remote"
        )
        workspace.configureRemoteConnection(config, autoConnect: false)
        _ = try #require(workspace.focusedTerminalPanel)
        return workspace
    }

    private func makeLocalWorkspaceWithTerminalPanel() throws -> Workspace {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        _ = try #require(workspace.focusedTerminalPanel)
        return workspace
    }

    // Add a terminal panel to a remote workspace that is NOT tracked as a
    // remote surface. suppressWorkspaceRemoteStartupCommand: true skips the
    // remote startup command so the panel does not enter
    // activeRemoteTerminalSurfaceIds.
    @discardableResult
    private func addLocalUntrackedTerminalPanel(to workspace: Workspace) throws -> UUID {
        let paneId = try #require(
            workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first
        )
        let panel = try #require(
            workspace.newTerminalSurface(
                inPane: paneId,
                focus: false,
                suppressWorkspaceRemoteStartupCommand: true
            )
        )
        return panel.id
    }

    @Test func respawnRewriteReroutesTrackedRemoteSurface() throws {
        let ws = try makeRemoteWorkspaceWithTrackedPanel()
        let panelId = ws.activeRemoteTerminalSurfaceIds.first!
        let raw = "cd /Users/bencollins/Development/Braid && env CLAUDECODE=1 claude --agent-id x"

        let rewrite = ws.remoteShimRespawnRewrite(panelId: panelId, rawCommand: raw)

        let r = try #require(rewrite)
        // Must NOT exec the raw command locally:
        #expect(!r.command.contains("Development/Braid"))
        // Must be the ssh-pty-attach bridge carrying the command as base64:
        #expect(r.command.contains("ssh-pty-attach"))
        #expect(r.command.contains(Data(raw.utf8).base64EncodedString()))
        // Must create the session (no --require-existing):
        #expect(!r.command.contains("--require-existing"))
        #expect(r.command.contains(r.sessionID))
    }

    @Test func respawnRewriteMintsFreshSessionIDs() throws {
        let ws = try makeRemoteWorkspaceWithTrackedPanel()
        let panelId = ws.activeRemoteTerminalSurfaceIds.first!
        let a = ws.remoteShimRespawnRewrite(panelId: panelId, rawCommand: "echo a")
        let b = ws.remoteShimRespawnRewrite(panelId: panelId, rawCommand: "echo b")
        #expect(try #require(a).sessionID != (try #require(b).sessionID))
        // Never the deterministic reattach ID — that would join a stale session:
        #expect(try #require(a).sessionID != Workspace.defaultSSHPTYSessionID(workspaceId: ws.id, panelId: panelId))
    }

    @Test func respawnRewriteLeavesLocalWorkspacesAlone() throws {
        let ws = try makeLocalWorkspaceWithTerminalPanel()
        let panelId = ws.panels.keys.first!
        #expect(ws.remoteShimRespawnRewrite(panelId: panelId, rawCommand: "echo x") == nil)
    }

    @Test func respawnRewriteLeavesUntrackedLocalPanesInRemoteWorkspaceAlone() throws {
        let ws = try makeRemoteWorkspaceWithTrackedPanel()
        let localPanelId = try addLocalUntrackedTerminalPanel(to: ws)
        #expect(ws.remoteShimRespawnRewrite(panelId: localPanelId, rawCommand: "echo x") == nil)
    }

    /// A respawn that replaces an existing remote session must surface the old
    /// session ID so callers can end it on the daemon.  Without this, the
    /// replaced persistent session lingers for its full 24-hour idle TTL.
    @Test func respawnBookkeepingEndsTrackedPreviousSession() throws {
        let ws = try makeRemoteWorkspaceWithTrackedPanel()
        let panelId = try #require(ws.activeRemoteTerminalSurfaceIds.first)
        let oldSessionID = "shim-old-\(ws.id.uuidString)-\(panelId.uuidString)-\(UUID().uuidString)"
        let newSessionID = "shim-new-\(ws.id.uuidString)-\(panelId.uuidString)-\(UUID().uuidString)"
        // Simulate the pane already having a tracked remote session from a prior respawn.
        ws.remotePTYSessionIDsByPanelId[panelId] = oldSessionID

        let endedSessionID = ws.applyRemoteShimRespawnBookkeeping(panelId: panelId, sessionID: newSessionID)

        // The old session ID must be returned so the caller can end it daemon-side.
        #expect(endedSessionID == oldSessionID)
        // The new session must be registered in its place.
        #expect(ws.remotePTYSessionIDsByPanelId[panelId] == newSessionID)
        // The panel must remain tracked as an active remote terminal.
        #expect(ws.activeRemoteTerminalSurfaceIds.contains(panelId))
    }

    /// A respawn on a pane with no prior remote session returns nil (nothing to end).
    @Test func respawnBookkeepingWithNoPreviousSessionReturnsNil() throws {
        let ws = try makeRemoteWorkspaceWithTrackedPanel()
        let panelId = try #require(ws.activeRemoteTerminalSurfaceIds.first)
        // Ensure no prior session is tracked for this panel.
        ws.remotePTYSessionIDsByPanelId.removeValue(forKey: panelId)
        let newSessionID = "shim-\(ws.id.uuidString)-\(panelId.uuidString)-\(UUID().uuidString)"

        let endedSessionID = ws.applyRemoteShimRespawnBookkeeping(panelId: panelId, sessionID: newSessionID)

        #expect(endedSessionID == nil)
        #expect(ws.remotePTYSessionIDsByPanelId[panelId] == newSessionID)
        #expect(ws.activeRemoteTerminalSurfaceIds.contains(panelId))
    }
}
