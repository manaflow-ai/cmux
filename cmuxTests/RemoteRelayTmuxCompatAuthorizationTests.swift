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
/// panes through relayed `surface.split` requests. The relay ingress gate
/// must admit those workspace-scoped pane mutations while
/// still refusing cross-workspace methods and foreign surface selectors.
@MainActor
@Suite(.serialized)
struct RemoteRelayTmuxCompatAuthorizationTests {
    private static let relayToken = String(repeating: "b", count: 64)

    @Test
    func workspaceDiscoveryReturnsOnlyOwnerIdentityOnBothDispatchLanes() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let manager = try #require(fixture.appDelegate.tabManager)
        let unrelated = try #require(manager.addWorkspaceIfActive(title: "PRIVATE LOCAL WORKSPACE", select: true))
        defer { _ = manager.closeWorkspaceNonInteractively(unrelated) }
        let admitted = try fixture.authorize(method: "workspace.list", params: [:])
        try #require(admitted.errorResponse == nil)
        let expected = ControlCallResult.ok(.object([
            "scope": .string("remote_workspace"),
            "workspaces": .array([.object([
                "id": .string(fixture.workspace.id.uuidString),
                "title": .string(fixture.workspace.title)
            ])])
        ]))
        let coordinator = ControlCommandCoordinator(context: TerminalController.shared)
        #expect(coordinator.handle(admitted.request) == expected)
        #expect(coordinator.handleSocketWorkerV2(admitted.request, context: TerminalController.shared) == expected)
        #expect(manager.selectedTabId == unrelated.id)

        // Discovering an ID grants no new methods or local terminal authority.
        let mutation = try fixture.authorize(method: "workspace.create", params: ["initial_command": "id"])
        #expect(mutation.errorResponse != nil)
        fixture.workspace.untrackRemoteTerminalSurface(fixture.panelID)
        let input = try fixture.authorize(method: "surface.send_text", params: [
            "workspace_id": fixture.workspace.id.uuidString,
            "surface_id": fixture.panelID.uuidString, "text": "id\n"
        ])
        #expect(input.errorResponse != nil)
        fixture.workspace.activeRemoteSessionControllerID = UUID()
        guard case .err? = coordinator.handleSocketWorkerV2(admitted.request, context: TerminalController.shared) else {
            Issue.record("Retired relay still enumerated a workspace")
            return
        }
    }

    @Test
    func coreDiscoveryRejectsForeignSelectorsAndSpoofedOrStaleProvenance() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let invalidSelectors: [Any] = [UUID().uuidString, "workspace:1", "", 17, NSNull(), [fixture.workspace.id.uuidString]]
        for value in invalidSelectors {
            let denied = try fixture.authorize(method: "workspace.list", params: ["workspace_id": value])
            #expect(denied.errorResponse != nil)
        }
        // Remote-supplied provenance is overwritten before the local MAC is minted.
        let request = try fixture.signedRequest(method: "workspace.list", params: [
            "_cmux_remote_workspace_id": UUID().uuidString,
            "_cmux_remote_connection_id": UUID().uuidString,
            "_cmux_remote_relay_request_authentication_code": "forged"
        ])
        #expect(request.params["_cmux_remote_workspace_id"] == .string(fixture.workspace.id.uuidString))
        #expect(TerminalController.shared.authorizeRemoteRelayRequest(request).errorResponse == nil)
        var forged = request.params
        forged["_cmux_remote_workspace_id"] = .string(UUID().uuidString)
        #expect(TerminalController.shared.authorizeRemoteRelayRequest(ControlRequest(
            id: request.id, method: request.method, params: forged)).errorResponse != nil)
        forged = request.params
        forged.removeValue(forKey: "_cmux_remote_relay_request_authentication_code")
        #expect(TerminalController.shared.authorizeRemoteRelayRequest(ControlRequest(
            id: request.id, method: request.method, params: forged)).errorResponse != nil)
        fixture.workspace.disconnectRemoteConnection(clearConfiguration: true)
        #expect(TerminalController.shared.authorizeRemoteRelayRequest(request).errorResponse != nil)
    }

    @Test
    func capabilitiesDescribeRelayScopeWithoutLocalDiscoveryMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let request = try fixture.signedRequest(method: "system.capabilities", params: [:])
        let signedLine = try JSONSerialization.data(withJSONObject: [
            "id": request.id?.foundationObject ?? NSNull(), "method": request.method,
            "params": request.params.mapValues(\.foundationObject)
        ])
        let command = String(decoding: signedLine, as: UTF8.self)
        let syncResponse = TerminalController.shared.handleSocketLine(command)
        let asyncResponse = try #require(await TerminalController.shared.processCommandUsingSocketExecutionPolicyAsync(command))
        for response in [syncResponse, asyncResponse] {
            let object = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            let result = try #require(object["result"] as? [String: Any])
            #expect(Set(result.keys) == ["protocol", "version", "methods", "scope"])
            #expect(result["scope"] as? String == "remote_workspace")
            let methods = try #require(result["methods"] as? [String])
            #expect(methods.contains("system.ping"))
            #expect(methods.contains("system.capabilities"))
            #expect(methods.contains("workspace.list"))
            for method in ["workspace.create", "surface.respawn", "system.tree", "system.command_spec", "browser.open"] {
                #expect(!methods.contains(method))
            }
        }
    }

    @Test
    func workspaceAliasesAreRewrittenButCannotGrantAnotherOwner() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let alias = UUID()
        for target in [fixture.workspace.id, UUID()] {
            let request = try fixture.signedRequest(method: "workspace.list",
                params: ["workspace_id": alias.uuidString], workspaceAliases: [alias: target])
            let authorization = TerminalController.shared.authorizeRemoteRelayRequest(request)
            #expect((authorization.errorResponse == nil) == (target == fixture.workspace.id))
        }
        let unknown = try fixture.authorize(method: "workspace.list", params: ["workspace_id": alias.uuidString])
        #expect(unknown.errorResponse != nil)
    }

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
            ("workspace.equalize_splits", ["workspace_id": workspaceID, "orientation": "vertical"]),
            ("surface.send_text", ["workspace_id": workspaceID, "surface_id": leaderSurfaceID, "text": "ls\n"]),
            ("surface.close", ["workspace_id": workspaceID, "surface_id": leaderSurfaceID]),
            ("surface.list", ["workspace_id": workspaceID]),
        ]
        for (method, params) in admitted {
            let authorization = try fixture.authorize(method: method, params: params)
            #expect(authorization.errorResponse == nil, "expected relay to admit \(method): \(authorization.errorResponse ?? "")")
            #expect(authorization.request.method == method)
            #expect(authorization.request.params["_cmux_remote_relay_request_authentication_code"] == nil)
        }

        let respawn = try fixture.authorize(method: "surface.respawn", params: [
            "workspace_id": workspaceID,
            "surface_id": leaderSurfaceID,
            "command": "echo remote",
        ])
        #expect(respawn.errorResponse?.contains("remote_relay_method_denied") == true)
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

        let foreignSurface = try fixture.authorize(method: "surface.send_text", params: [
            "workspace_id": workspaceID,
            "surface_id": UUID().uuidString,
            "text": "echo foreign",
        ])
        #expect(foreignSurface.errorResponse?.contains("remote_relay_surface_denied") == true)

        let missingSurface = try fixture.authorize(method: "surface.split", params: [
            "workspace_id": workspaceID,
            "direction": "right",
        ])
        #expect(missingSurface.errorResponse?.contains("remote_relay_surface_denied") == true)

        let missingWorkspace = try fixture.authorize(method: "workspace.equalize_splits", params: ["orientation": "vertical"])
        #expect(missingWorkspace.errorResponse?.contains("remote_relay_workspace_denied") == true)

        // Selector aliases satisfy the generic requirement checks but are
        // ignored by the tmux-compat handlers, which would fall back to the
        // selected workspace / focused surface. Exact keys are mandatory.
        let aliasWorkspace = try fixture.authorize(method: "workspace.current", params: [
            "preferred_workspace_id": fixture.workspace.id.uuidString,
        ])
        #expect(aliasWorkspace.errorResponse?.contains("remote_relay_workspace_denied") == true)

        let aliasSurface = try fixture.authorize(method: "surface.split", params: [
            "workspace_id": fixture.workspace.id.uuidString,
            "target_surface_id": fixture.panelID.uuidString,
            "direction": "right",
        ])
        #expect(aliasSurface.errorResponse?.contains("remote_relay_surface_denied") == true)
    }

    @Test
    func reporterTerminalIDAliasCannotTargetAnUnownedSurface() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        fixture.workspace.untrackRemoteTerminalSurface(fixture.panelID)
        // This is the reported wire shape: an owned decoy workspace selector
        // accompanies terminal_id, which the dispatcher accepts as a surface
        // alias. The method-specific schema must reject the decoy before the
        // request can reach the local socket.
        let authorization = try fixture.authorize(method: "surface.send_text", params: [
            "preferred_workspace_id": fixture.workspace.id.uuidString,
            "terminal_id": fixture.panelID.uuidString,
            "text": "touch /tmp/pwned\n",
        ])
        #expect(authorization.errorResponse?.contains("remote_relay") == true)
        let enter = try fixture.authorize(method: "surface.send_key", params: [
            "preferred_workspace_id": fixture.workspace.id.uuidString,
            "terminal_id": fixture.panelID.uuidString,
            "key": "Enter",
        ])
        #expect(enter.errorResponse?.contains("remote_relay_method_denied") == true)
    }

    @Test
    func unknownMethodWithOwnedSelectorsRemainsDenied() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let authorization = try fixture.authorize(method: "future.execute", params: [
            "workspace_id": fixture.workspace.id.uuidString,
            "surface_id": fixture.panelID.uuidString,
        ])
        #expect(authorization.errorResponse?.contains("remote_relay_method_denied") == true)
    }

    @Test
    func liveOwnershipRevocationInvalidatesAnAlreadyKnownSurface() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let params: [String: Any] = [
            "workspace_id": fixture.workspace.id.uuidString,
            "surface_id": fixture.panelID.uuidString,
            "text": "echo scoped\n",
        ]

        let admitted = try fixture.authorize(method: "surface.send_text", params: params)
        #expect(admitted.errorResponse == nil)
        fixture.workspace.untrackRemoteTerminalSurface(fixture.panelID)
        let revoked = try fixture.authorize(method: "surface.send_text", params: params)
        #expect(revoked.errorResponse?.contains("remote_relay_surface_denied") == true)
    }

    @Test
    func admittedRequestCannotOutliveItsConnectionAtDispatch() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.workspace.activeRemoteSessionControllerID = UUID()
        let admitted = try fixture.authorize(method: "surface.list", params: [
            "workspace_id": fixture.workspace.id.uuidString,
        ])
        try #require(admitted.errorResponse == nil)
        let coordinator = ControlCommandCoordinator(context: TerminalController.shared)
        guard case .ok? = coordinator.handle(admitted.request) else {
            Issue.record("An active connection must be able to list its surfaces")
            return
        }
        // Same workspace and same terminal UUIDs, but a replacement SSH
        // controller now owns them. The previously admitted request is stale.
        fixture.workspace.activeRemoteSessionControllerID = UUID()
        guard case .err? = coordinator.handle(admitted.request) else {
            Issue.record("A request admitted for the retired connection reached dispatch")
            return
        }
        guard case .err? = coordinator.handleSocketWorkerV2(admitted.request, context: TerminalController.shared) else {
            Issue.record("A retired connection reached the socket-worker dispatch path")
            return
        }
    }

    @Test
    func relayListingDoesNotExposeLocalPanelsInsideItsWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let admitted = try fixture.authorize(method: "surface.list", params: [
            "workspace_id": fixture.workspace.id.uuidString,
        ])
        try #require(admitted.errorResponse == nil)
        fixture.workspace.untrackRemoteTerminalSurface(fixture.panelID)
        let coordinator = ControlCommandCoordinator(context: TerminalController.shared)
        guard case .ok(.object(let result))? = coordinator.handle(admitted.request) else {
            Issue.record("A live connection must still be able to list its remote panels")
            return
        }
        #expect(result["surfaces"] == .array([]))
        let globalTree = try fixture.authorize(method: "system.tree", params: [
            "workspace_id": fixture.workspace.id.uuidString,
        ])
        #expect(globalTree.errorResponse?.contains("remote_relay_method_denied") == true)
    }

    @Test
    func retiredConnectionIsDeniedByAsyncIngress() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let request = try fixture.signedRequest(method: "surface.read_selection", params: [
            "workspace_id": fixture.workspace.id.uuidString,
            "terminal_id": fixture.panelID.uuidString,
        ])
        let admitted = await TerminalController.shared.authorizeRemoteRelayRequestAsync(request)
        try #require(admitted.errorResponse == nil)
        fixture.workspace.activeRemoteSessionControllerID = UUID()
        let retired = await TerminalController.shared.authorizeRemoteRelayRequestAsync(request)
        #expect(retired.errorResponse?.contains("remote_relay_authentication_failed") == true)
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
            let restoredAppDelegate = AppDelegate.shared
            let delegate = restoredAppDelegate ?? AppDelegate()
            let restoredTabManager = delegate.tabManager
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let registeredWindowID = delegate.registerMainWindowContextForTesting(tabManager: manager)
            AppDelegate.shared = delegate
            delegate.tabManager = manager
            let resolvedWorkspace: Workspace
            let resolvedPanelID: UUID
            do {
                resolvedWorkspace = try #require(manager.selectedWorkspace)
                resolvedPanelID = try #require(resolvedWorkspace.focusedPanelId)
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
                try #require(
                    resolvedWorkspace.configureRemoteConnection(configuration, autoConnect: false)
                )
                resolvedWorkspace.trackRemoteTerminalSurface(resolvedPanelID)
                resolvedWorkspace.activeRemoteSessionControllerID = UUID()
            } catch {
                // A throwing `#require` must not leak the shared-state
                // mutations above into later tests: roll them back before
                // rethrowing, exactly as `tearDown()` would have.
                delegate.unregisterMainWindowContextForTesting(windowId: registeredWindowID)
                delegate.tabManager = restoredTabManager
                AppDelegate.shared = restoredAppDelegate
                throw error
            }
            workspace = resolvedWorkspace
            panelID = resolvedPanelID
            previousAppDelegate = restoredAppDelegate
            appDelegate = delegate
            previousTabManager = restoredTabManager
            windowID = registeredWindowID
        }

        func authorize(method: String, params: [String: Any]) throws -> TerminalController.RemoteRelayAuthorizationResult {
            TerminalController.shared.authorizeRemoteRelayRequest(try signedRequest(method: method, params: params))
        }

        func signedRequest(method: String, params: [String: Any], workspaceAliases: [UUID: UUID] = [:]) throws -> ControlRequest {
            let request: [String: Any] = [
                "id": "relay-\(method)",
                "method": method,
                "params": params,
            ]
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(0x0A)
            let rewritten = WorkspaceRemoteRelayCommandRewriter(
                remoteWorkspaceID: workspace.id,
                remoteRelayTokenHex: RemoteRelayTmuxCompatAuthorizationTests.relayToken,
                remoteSessionControllerID: workspace.activeRemoteSessionControllerID
            ).rewriteRemoteRelayCommandLine(data, workspaceAliases: workspaceAliases, surfaceAliases: [:])
            let line = try #require(String(data: rewritten, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard case .success(let parsed) = ControlRequestParser().request(fromLine: line) else {
                throw NSError(domain: "RemoteRelayTmuxCompatAuthorizationTests", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "relay request did not parse: \(line.prefix(200))",
                ])
            }
            return parsed
        }

        func tearDown() {
            workspace.disconnectRemoteConnection(clearConfiguration: true)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            appDelegate.tabManager = previousTabManager
            AppDelegate.shared = previousAppDelegate
        }
    }
}
