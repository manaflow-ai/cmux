import AppKit
import CmuxControlSocket
import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The remote tmux shim (`cmux claude-teams` on the SSH host) drives teammate
/// panes through relayed `surface.split` / `surface.respawn` requests. The
/// relay ingress gate must admit those workspace-scoped pane mutations while
/// still refusing cross-workspace methods and foreign surface selectors.
@MainActor
@Suite(.serialized)
struct RemoteRelayTmuxCompatAuthorizationTests {
    private static let relayToken = String(repeating: "b", count: 64)

    @Test
    func relayAdmitsWorkspaceScopedTeammatePaneMutations() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let workspaceID = fixture.workspace.id.uuidString
        let leaderSurfaceID = fixture.panelID.uuidString

        let admitted: [(String, [String: Any])] = [
            ("surface.split", [
                "workspace_id": workspaceID, "surface_id": leaderSurfaceID,
                "direction": "right", "focus": false,
            ]),
            ("surface.respawn", [
                "workspace_id": workspaceID, "surface_id": leaderSurfaceID,
                "command": "/bin/sh -c 'cd /data00/remote-only && claude --agent-id t1@team'",
                "tmux_start_command": "cd /data00/remote-only && claude --agent-id t1@team",
            ]),
            ("workspace.equalize_splits", ["workspace_id": workspaceID, "orientation": "vertical"]),
            ("surface.send_text", ["workspace_id": workspaceID, "surface_id": leaderSurfaceID, "text": "ls\n"]),
            ("surface.close", ["workspace_id": workspaceID, "surface_id": leaderSurfaceID]),
            ("pane.list", ["workspace_id": workspaceID]),
        ]
        for (method, params) in admitted {
            let authorization = try fixture.authorize(method: method, params: params)
            #expect(authorization.errorResponse == nil, "expected relay to admit \(method): \(authorization.errorResponse ?? "")")
            #expect(authorization.request.method == method)
            #expect(authorization.request.params["_cmux_remote_relay_request_authentication_code"] == nil)
        }
    }

    @Test
    func relayStillRefusesCrossWorkspaceAndForeignSurfaceRequests() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let workspaceID = fixture.workspace.id.uuidString

        let created = try fixture.authorize(method: "workspace.create", params: ["focus": false])
        #expect(created.errorResponse?.contains("remote_relay_method_denied") == true)

        let closedWorkspace = try fixture.authorize(method: "workspace.close", params: ["workspace_id": workspaceID])
        #expect(closedWorkspace.errorResponse?.contains("remote_relay_method_denied") == true)

        let foreignSurface = try fixture.authorize(method: "surface.respawn", params: [
            "workspace_id": workspaceID,
            "surface_id": UUID().uuidString,
            "command": "echo foreign",
        ])
        #expect(foreignSurface.errorResponse?.contains("remote_relay_surface_denied") == true)

        let missingSurface = try fixture.authorize(method: "surface.split", params: [
            "workspace_id": workspaceID,
            "direction": "right",
        ])
        #expect(missingSurface.errorResponse?.contains("remote_relay_surface_denied") == true)

        let missingWorkspace = try fixture.authorize(method: "workspace.equalize_splits", params: ["orientation": "vertical"])
        #expect(missingWorkspace.errorResponse?.contains("remote_relay_workspace_denied") == true)
    }

    @MainActor
    private struct Fixture {
        let appDelegate: AppDelegate
        let previousAppDelegate: AppDelegate?
        let previousTabManager: TabManager?
        let windowID: UUID
        let workspace: Workspace
        let panelID: UUID

        init() throws {
            previousAppDelegate = AppDelegate.shared
            appDelegate = previousAppDelegate ?? AppDelegate()
            previousTabManager = appDelegate.tabManager
            let manager = TabManager(autoWelcomeIfNeeded: false)
            windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            workspace = try #require(manager.selectedWorkspace)
            panelID = try #require(workspace.focusedPanelId)
            let configuration = WorkspaceRemoteConfiguration(
                transport: .ssh,
                terminalTransport: .ssh,
                destination: "tiny@remote-only",
                port: 22,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 22049,
                relayID: "cmux-11049-relay",
                relayToken: RemoteRelayTmuxCompatAuthorizationTests.relayToken,
                localSocketPath: nil,
                terminalStartupCommand: "cmux remote-shell",
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "cmux-11049-relay",
                skipDaemonBootstrap: false
            )
            #expect(workspace.configureRemoteConnection(configuration, autoConnect: false))
            workspace.trackRemoteTerminalSurface(panelID)
        }

        func authorize(method: String, params: [String: Any]) throws -> TerminalController.RemoteRelayAuthorizationResult {
            let request: [String: Any] = [
                "id": "relay-\(method)",
                "method": method,
                "params": params,
            ]
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(0x0A)
            let rewritten = WorkspaceRemoteRelayCommandRewriter(
                remoteWorkspaceID: workspace.id,
                remoteRelayTokenHex: RemoteRelayTmuxCompatAuthorizationTests.relayToken
            ).rewriteRemoteRelayCommandLine(data, workspaceAliases: [:], surfaceAliases: [:])
            let line = try #require(String(data: rewritten, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard case .success(let parsed) = ControlRequestParser().request(fromLine: line) else {
                throw NSError(domain: "RemoteRelayTmuxCompatAuthorizationTests", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "relay request did not parse: \(line.prefix(200))",
                ])
            }
            return TerminalController.shared.authorizeRemoteRelayRequest(parsed)
        }

        func tearDown() {
            workspace.disconnectRemoteConnection(clearConfiguration: true)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            appDelegate.tabManager = previousTabManager
            AppDelegate.shared = previousAppDelegate
        }
    }
}
