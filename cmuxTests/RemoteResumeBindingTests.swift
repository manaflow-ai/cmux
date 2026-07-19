import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct RemoteResumeBindingTests {
    private let relayPort = 64_089

    @Test
    func emptyPersistentSessionIDsNeverMatch() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let context = SurfaceResumeRemoteContext(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            persistentPTYSessionID: ""
        )

        #expect(!context.matches(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            persistentPTYSessionID: "   "
        ))
    }

    @Test
    func relayedRegistrationUsesExplicitRemoteFlavorAfterAliasRewrite() throws {
        let fixture = try makeRelayedFixture()

        #expect(fixture.localBinding["execution_location"] as? String == "local")
        #expect(fixture.localBinding["remote_workspace_id"] is NSNull)
        #expect(fixture.spoofedRelayRegistrationRejected)
        #expect(fixture.remoteBinding["execution_location"] as? String == "remote_ssh")
        #expect(fixture.remoteBinding["remote_workspace_id"] as? String == fixture.workspaceID.uuidString)
        #expect(fixture.remoteBinding["remote_surface_id"] as? String == fixture.surfaceID.uuidString)
        #expect(fixture.remoteBinding["remote_pty_session_id"] as? String == fixture.remotePTYSessionID)
        #expect(fixture.remoteBinding["cwd"] as? String == "/srv/remote project")
        #expect(fixture.remoteBinding["auto_resume"] as? Bool == true)

        let environment = try #require(fixture.remoteBinding["environment"] as? [String: Any])
        #expect(environment["REMOTE_FLAG"] as? String == "value with spaces")
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
    }

    @Test
    func persistentRestoreRunsRemoteResumeOnlyWhenSessionMustBeCreated() throws {
        let fixture = try makeRelayedFixture()
        let suiteName = "cmux-remote-resume-binding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let socketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(socketPath) }

        let restoredWorkspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let restoredIDs = restoredWorkspace.restoreSessionSnapshot(fixture.snapshot)
        let restoredSurfaceID = try #require(restoredIDs[fixture.surfaceID])
        let restoredPanel = try #require(restoredWorkspace.terminalPanel(for: restoredSurfaceID))
        let liveFirstCommand = try #require(restoredPanel.surface.debugInitialCommand())

        #expect(liveFirstCommand.contains("ssh-pty-attach"), "\(liveFirstCommand)")
        #expect(liveFirstCommand.contains("--require-existing"), "\(liveFirstCommand)")
        let liveFirstRemoteCommand = try decodedRemoteCommand(from: liveFirstCommand)
        try expectRemoteResumeBootstrap(
            liveFirstRemoteCommand,
            workspaceID: restoredWorkspace.id,
            surfaceID: restoredSurfaceID
        )
        #expect(restoredPanel.surface.debugInitialInputForTesting() == nil)

        let roundTrip = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        let roundTripBinding = try #require(
            roundTrip.panels.first { $0.id == restoredSurfaceID }?.terminal?.resumeBinding
        )
        let encodedBinding = try JSONEncoder().encode(roundTripBinding)
        let bindingObject = try #require(
            JSONSerialization.jsonObject(with: encodedBinding) as? [String: Any]
        )
        let launchFlavor = try #require(bindingObject["launchFlavor"] as? [String: Any])
        #expect(launchFlavor["kind"] as? String == "persistentSSH")
        let remoteContext = try #require(launchFlavor["remoteContext"] as? [String: Any])
        #expect(remoteContext["workspaceID"] as? String == restoredWorkspace.id.uuidString)
        #expect(remoteContext["surfaceID"] as? String == restoredSurfaceID.uuidString)
        #expect(remoteContext["persistentPTYSessionID"] as? String == fixture.remotePTYSessionID)

        let ended = restoredWorkspace.markRemotePTYAttachEnded(
            surfaceId: restoredSurfaceID,
            sessionID: fixture.remotePTYSessionID
        )
        #expect(ended.clearedRemotePTYSession)
        restoredWorkspace.markPersistentRemotePTYAttachFailed(surfaceId: restoredSurfaceID)
        let restarted = restoredWorkspace.reattachPersistentRemotePTYPanels(
            requestedSurfaceId: restoredSurfaceID,
            restartEndedSessions: true
        )
        #expect(restarted == [restoredSurfaceID])

        let gonePTYCommand = try #require(
            restoredWorkspace.terminalPanel(for: restoredSurfaceID)?.surface.debugInitialCommand()
        )
        #expect(!gonePTYCommand.contains("--require-existing"), "\(gonePTYCommand)")
        let gonePTYRemoteCommand = try decodedRemoteCommand(from: gonePTYCommand)
        try expectRemoteResumeBootstrap(
            gonePTYRemoteCommand,
            workspaceID: restoredWorkspace.id,
            surfaceID: restoredSurfaceID
        )
    }

    private func makeRelayedFixture() throws -> (
        snapshot: SessionWorkspaceSnapshot,
        workspaceID: UUID,
        surfaceID: UUID,
        remotePTYSessionID: String,
        localBinding: [String: Any],
        spoofedRelayRegistrationRejected: Bool,
        remoteBinding: [String: Any]
    ) {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        let windowID = UUID()
        let window = makeMainWindow(id: windowID)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: false)

        let localResult = try v2Result(
            request: [
                "id": "local-resume-set",
                "method": "surface.resume.set",
                "params": remoteResumeParams(
                    workspaceID: workspace.id,
                    surfaceID: surfaceID,
                    command: "codex resume local-session"
                ),
            ]
        )
        let localBinding = try #require(localResult["resume_binding"] as? [String: Any])

        var spoofedParams = remoteResumeParams(
            workspaceID: workspace.id,
            surfaceID: surfaceID,
            command: "codex resume forged-local-request"
        )
        spoofedParams["_cmux_remote_workspace_id"] = workspace.id.uuidString
        spoofedParams["_cmux_remote_relay_authentication_code"] = String(repeating: "0", count: 64)
        let spoofedEnvelope = try v2Envelope(request: [
            "id": "spoofed-relay-resume-set",
            "method": "surface.resume.set",
            "params": spoofedParams,
        ])
        let bindingAfterSpoof = try v2Result(request: [
            "id": "resume-get-after-spoof",
            "method": "surface.resume.get",
            "params": [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
            ],
        ])["resume_binding"] as? [String: Any]
        let spoofedRelayRegistrationRejected = spoofedEnvelope["ok"] as? Bool == false
            && (bindingAfterSpoof?["command"] as? String) == (localBinding["command"] as? String)

        let staleWorkspaceID = UUID()
        let staleSurfaceID = UUID()
        let remotePTYSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: staleWorkspaceID,
            panelId: staleSurfaceID
        )
        workspace.remotePTYSessionIDsByPanelId[surfaceID] = remotePTYSessionID
        workspace.registerRemoteRelayIDAliases(
            remotePTYSessionID: remotePTYSessionID,
            restoredPanelId: surfaceID
        )

        let relayedRequest: [String: Any] = [
            "id": "relayed-resume-set",
            "method": "surface.resume.set",
            "params": remoteResumeParams(
                workspaceID: staleWorkspaceID,
                surfaceID: staleSurfaceID,
                command: "cd '/srv/remote project' && '/home/dev/.nvm/versions/node/v24/bin/codex' resume session-remote-7989"
            ),
        ]
        var relayedData = try JSONSerialization.data(withJSONObject: relayedRequest)
        relayedData.append(0x0A)
        let rewrittenData = workspace.rewriteRemoteRelayCommandLine(relayedData)
        let remoteResult = try v2Result(requestData: rewrittenData)
        let remoteBinding = try #require(remoteResult["resume_binding"] as? [String: Any])

        return (
            workspace.sessionSnapshot(includeScrollback: false),
            workspace.id,
            surfaceID,
            remotePTYSessionID,
            localBinding,
            spoofedRelayRegistrationRejected,
            remoteBinding
        )
    }

    private func remoteConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 22,
            identityFile: nil,
            sshOptions: ["StrictHostKeyChecking=accept-new"],
            localProxyPort: nil,
            relayPort: relayPort,
            relayID: "relay-issue-7989",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-issue-7989.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(requireExisting: false),
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-issue-7989"
        )
    }

    private func remoteResumeParams(
        workspaceID: UUID,
        surfaceID: UUID,
        command: String
    ) -> [String: Any] {
        [
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
            "name": "Codex",
            "kind": "codex",
            "checkpoint_id": "session-remote-7989",
            "source": "agent-hook",
            "command": command,
            "cwd": "/srv/remote project",
            "environment": [
                "REMOTE_FLAG": "value with spaces",
                "ANTHROPIC_API_KEY": "must-not-persist",
            ],
            "auto_resume": true,
        ]
    }

    private func v2Result(request: [String: Any]) throws -> [String: Any] {
        let envelope = try v2Envelope(request: request)
        #expect(envelope["ok"] as? Bool == true, "\(envelope)")
        return try #require(envelope["result"] as? [String: Any])
    }

    private func v2Envelope(request: [String: Any]) throws -> [String: Any] {
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        let requestLine = try #require(String(data: data, encoding: .utf8))
        let response = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(response.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func v2Result(requestData: Data) throws -> [String: Any] {
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let response = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(response.data(using: .utf8))
        let envelope = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        #expect(envelope["ok"] as? Bool == true, "\(response)")
        return try #require(envelope["result"] as? [String: Any])
    }

    private func decodedRemoteCommand(from startupCommand: String) throws -> String {
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(startupCommand).map(\.value)
        let script = try #require(words.dropFirst(2).first)
        let range = try #require(
            script.range(of: #"--command-b64 [A-Za-z0-9+/=]+"#, options: .regularExpression)
        )
        let encoded = String(script[range]).split(separator: " ", maxSplits: 1).last.map(String.init)
        let data = try #require(encoded.flatMap(Data.init(base64Encoded:)))
        return try #require(String(data: data, encoding: .utf8))
    }

    private func expectRemoteResumeBootstrap(
        _ command: String,
        workspaceID: UUID,
        surfaceID: UUID
    ) throws {
        #expect(command.contains("export CMUX_SOCKET_PATH=127.0.0.1:\(relayPort)"), "\(command)")
        #expect(command.contains("__CMUX_WORKSPACE_ID__"), "\(command)")
        #expect(command.contains("__CMUX_SURFACE_ID__"), "\(command)")
        #expect(command.contains("/srv/remote project"), "\(command)")
        #expect(command.contains("REMOTE_FLAG=value with spaces"), "\(command)")
        #expect(command.contains("session-remote-7989"), "\(command)")
        #expect(!command.contains("ANTHROPIC_API_KEY"), "\(command)")
        _ = workspaceID
        _ = surfaceID
    }

    private func reserveRemoteRestoreSocket() -> String {
        TerminalController.shared.stop()
        let requestedPath = "/tmp/cmux-remote-resume-\(UUID().uuidString).sock"
        return TerminalController.shared.reserveStartupSocketPath(requestedPath)
    }

    private func cleanupRemoteRestoreSocket(_ path: String) {
        TerminalController.shared.stop()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + ".lock")
    }

    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }
}
