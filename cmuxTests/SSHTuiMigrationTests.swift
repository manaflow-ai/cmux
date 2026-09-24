import CmuxCore
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("SSH cmux-tui migration", .serialized)
struct SSHTuiMigrationTests {
    private func configuration(options: [String] = [], command: String? = nil, identityFile: String = "/tmp/key with spaces", profile: WorkspaceRemoteTerminalProfile = .shell) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            terminalProfile: profile, destination: "alice@example.invalid", port: 2222, identityFile: identityFile,
            sshOptions: options, localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, configuredRemoteCommand: command,
            preserveAfterTerminalExit: true
        )
    }

    @Test("Provider defaults retain the SSH command and terminal profile")
    func providerDefaultUsesSSHLaunchConfiguration() {
        let command = "printf configured-command"
        let configured = SSHTuiConnection(configuration: configuration(command: command))
        #expect(RemoteTuiMachine.ssh(configured).defaultTerminalCommand ==
                ["/bin/sh", "-c", "exec \"${SHELL:-/bin/sh}\" -lc \"$1\"", "cmux-ssh", command])
        let tmux = SSHTuiConnection(configuration: configuration(command: command, profile: .defaultTmux))
        #expect(RemoteTuiMachine.ssh(tmux).defaultTerminalCommand ==
                WorkspaceRemoteTerminalProfile.defaultTmux.remoteCommandArguments)
        let shell = SSHTuiConnection(configuration: configuration())
        #expect(RemoteTuiMachine.ssh(shell).defaultTerminalCommand ==
                ["/bin/sh", "-c", "exec \"${SHELL:-/bin/sh}\" -l"])
    }

    @Test("OpenSSH resolves the cmux-tui carrier as a non-PTY exec channel")
    func carrierOverridesInteractiveHostDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key with spaces")
        try Data().write(to: key)
        let connection = SSHTuiConnection(configuration: configuration(options: [
            "RequestTTY=force", "RemoteCommand=interactive-only", "StrictHostKeyChecking=yes",
        ], identityFile: key.path))
        let arguments = connection.arguments(stateDirectory: "/tmp/client state", deviceName: "test")
        let sshArguments = arguments.indices.compactMap { index -> String? in
            guard index > 0, arguments[index - 1] == "--ssh-arg" else { return nil }
            return arguments[index]
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", "/dev/null"] + sshArguments + [connection.configuration.destination]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let values = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(values.contains("requesttty false"))
        #expect(!values.contains(where: { $0.hasPrefix("remotecommand ") }))
        #expect(values.contains("port 2222"))
        #expect(values.contains("stricthostkeychecking true"))
        #expect(values.contains(Substring("identityfile " + key.path)))
    }

    @Test("Changing a ControlMaster path does not change persistent SSH terminal identity")
    func sessionIdentitySurvivesCarrierReplacement() {
        let first = SSHTuiConnection(configuration: configuration(options: ["ControlPath=/tmp/first", "ProxyJump=bastion"]))
        let replacement = SSHTuiConnection(configuration: configuration(options: ["ControlPath=/tmp/second", "ProxyJump=bastion"]))
        let otherRoute = SSHTuiConnection(configuration: configuration(options: ["ProxyJump=another-host"]))
        #expect(first.id == replacement.id)
        #expect(first.id != otherRoute.id)
        #expect(SurfaceMachineID(rawValue: first.id).isSSH)
        #expect(SurfaceMachineID(rawValue: first.id).cloudMachineID == nil)
    }

    @Test("Saved SSH connections restore without executing the retired PTY wrapper")
    func restorePreservesEndpointWithoutLegacyDaemonLaunch() throws {
        let original = configuration(options: ["ProxyJump=bastion"], command: "exec fish -l")
        let snapshot = try #require(original.sessionSnapshot())
        let persisted = try JSONEncoder().encode(snapshot)
        let restored = try #require(try JSONDecoder().decode(SessionRemoteWorkspaceSnapshot.self, from: persisted).workspaceConfiguration())
        #expect(restored.destination == original.destination)
        #expect(restored.port == original.port)
        #expect(restored.configuredRemoteCommand == original.configuredRemoteCommand)
        #expect(restored.preserveAfterTerminalExit)
        #expect(restored.terminalStartupCommand == nil)
        #expect(restored.relayPort == nil)
        #expect(restored.foregroundAuthToken == nil)
        #expect(SSHTuiConnection(configuration: original).id == SSHTuiConnection(configuration: restored).id)
    }

    @Test("SSH projection identities survive session serialization without becoming Cloud machines")
    func projectionRoundTripRetainsSSHBackend() throws {
        let id = SSHTuiConnection(configuration: configuration()).id
        let record = SurfaceProjectionRecord(panelID: UUID(), resource: SurfaceResourceID(
            machine: SurfaceMachineID(rawValue: id), kind: .terminal, key: "term_persistent"
        ), remoteWorkspaceID: "ws_persistent", remoteTabID: "tab_persistent")
        let decoded = try JSONDecoder().decode(SurfaceProjectionRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.resource == record.resource)
        #expect(decoded.remoteWorkspaceID == "ws_persistent")
        #expect(decoded.remoteTabID == "tab_persistent")
        #expect(decoded.resource.machine.isSSH)
    }

    @MainActor
    @Test("Native SSH projections remain remote before and after provider restore")
    func nativeSSHProjectionOwnsAgentAndPathClassification() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let catalog = SurfaceCatalog.shared
        defer {
            catalog.endProjections(panelID: panelID, reason: .replaced)
            workspace.teardownAllPanels()
        }
        #expect(!workspace.isRemoteTerminalContext(panelID))
        #expect(workspace.canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: panelID))
        workspace.remoteConfiguration = configuration()
        let resource = SurfaceResourceID(
            machine: SurfaceMachineID(rawValue: SSHTuiConnection(configuration: configuration()).id),
            kind: .terminal, key: "term_" + UUID().uuidString
        )
        catalog.restore([SurfaceProjectionRecord(panelID: panelID, resource: resource)],
                        workspaceID: workspace.id, restoringWorkspace: workspace)
        try #require(catalog.projectionIncludingPendingRestore(forPanel: panelID)?.resource == resource)
        #expect(workspace.activeRemoteTerminalSurfaceIds.isEmpty)
        #expect(workspace.isRemoteTerminalContext(panelID))
        #expect(!workspace.canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: panelID))
        #expect(!workspace.isRemoteTerminalContext(UUID()))
        catalog.endProjections(panelID: panelID, reason: .replaced)
        #expect(!workspace.isRemoteTerminalContext(panelID))
        #expect(workspace.canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: panelID))
    }

    @Test("Native SSH forks never fall back to local creation without a provider")
    @MainActor
    func disconnectedNativeSSHForkFailsClosed() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: panelID))
        let tabID = try #require(workspace.surfaceIdFromPanelId(panelID))
        let catalog = SurfaceCatalog.shared
        defer {
            catalog.endProjections(panelID: panelID, reason: .replaced)
            workspace.teardownAllPanels()
        }
        let config = configuration()
        workspace.remoteConfiguration = config
        let resource = SurfaceResourceID(machine: .init(rawValue: SSHTuiConnection(configuration: config).id),
                                         kind: .terminal, key: "fork-test-" + UUID().uuidString)
        catalog.restore([SurfaceProjectionRecord(panelID: panelID, resource: resource)],
                        workspaceID: workspace.id, restoringWorkspace: workspace)
        let snapshot = SessionRestorableAgentSnapshot(kind: .claude,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951", workingDirectory: "/home/alice/project")
        let originalPanels = Set(workspace.panels.keys)
        #expect(workspace.forkAgentConversation(fromPanelId: panelID, snapshot: snapshot, direction: .right) == nil)
        #expect(workspace.forkAgentConversationToNewTab(fromPanelId: panelID, snapshot: snapshot,
                                                       anchorTabId: tabID, paneId: paneID) == nil)
        #expect(Set(workspace.panels.keys) == originalPanels)
        let launch = try #require(workspace.forkAgentWorkspaceLaunch(fromPanelId: panelID, snapshot: snapshot))
        let forkConfiguration = try #require(launch.remoteConfiguration)
        #expect(SSHTuiConnection(configuration: forkConfiguration).id == resource.machine.rawValue)
        #expect(forkConfiguration.configuredRemoteCommand == snapshot.forkCommand)
        #expect(launch.initialTerminalCommand == nil)
        #expect(launch.initialTerminalInput.isEmpty)
        #expect(launch.startupRestoreAgent == nil)
        #expect(launch.autoConnectRemoteConfiguration)
    }

    @Test("Native SSH respawn preserves its surface and executes only through the provider")
    @MainActor
    func nativeSSHRespawnUsesProviderReplacement() async throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let tabID = try #require(workspace.surfaceIdFromPanelId(panelID))
        let config = configuration()
        let connection = SSHTuiConnection(configuration: config)
        workspace.remoteConfiguration = config
        let catalog = SurfaceCatalog.shared
        let provider = CloudTerminalPlacementTestProvider(machine: .init(rawValue: connection.id))
        catalog.register(provider)
        defer {
            provider.release.resolve(true)
            catalog.unregister(machine: provider.machine)
            workspace.teardownAllPanels()
        }
        let original = provider.resource(key: "original")
        catalog.upsert(original, from: provider)
        catalog.record(SurfaceProjection(resource: original.id, workspaceID: workspace.id, panelID: panelID,
            remoteWorkspaceID: provider.remote.id, remoteTabID: "tab-original"))
        let replacement = try #require(workspace.respawnTerminalSurface(
            panelId: panelID, command: "printf remote-only", workingDirectory: "/remote/project", focus: false))
        #expect(replacement.id == panelID)
        #expect(replacement.surface.ioMode == .manualMirror)
        #expect(workspace.surfaceIdFromPanelId(panelID) == tabID)
        _ = await provider.creationStarted.result
        #expect(provider.closedTerminals == [original.id])
        #expect(provider.requestedCommands == [connection.commandArguments("printf remote-only")])
        #expect(provider.requestedDirectories == ["/remote/project"])
        #expect(provider.requestedWorkspaces == [provider.remote.id])
        provider.release.resolve(true)
        _ = await provider.materializationFinished.result
        #expect(provider.materialized.last?.panelID == panelID)
        #expect(provider.materialized.last?.resource.machine == provider.machine)
    }

    @Test("An all-session query with no native SSH workspaces retains legacy dispatch")
    @MainActor
    func allSessionsWithoutNativeWorkspacesFallsBack() async {
        let result = await TerminalController.shared.tuiSSHSessions(params: ["all_workspaces": true])
        #expect(result == nil)
    }

    @Test("All sessions includes both owners and preserves partial listing errors")
    func mixedSessionListsPreserveRowsAndErrors() throws {
        let result = TerminalController.shared.mergeRemotePTYSessionLists(
            tui: .ok(["workspace_count": 2,
                      "sessions": [["session_id": "term_native", "workspace_id": "native"]],
                      "errors": [["workspace_id": "native-offline", "error": "offline"]]]),
            legacy: .ok(["workspace_count": 2,
                         "sessions": [["session_id": "legacy-session", "workspace_id": "legacy"]],
                         "errors": [["workspace_id": "legacy-offline", "error": "offline"]]])
        )
        guard case .ok(let raw) = result else { Issue.record("Expected a combined session list"); return }
        let payload = try #require(raw as? [String: Any])
        #expect(payload["all_workspaces"] as? Bool == true)
        #expect(payload["workspace_count"] as? Int == 4)
        let sessions = try #require(payload["sessions"] as? [[String: Any]])
        #expect(sessions.compactMap { $0["workspace_id"] as? String } == ["native", "legacy"])
        let errors = try #require(payload["errors"] as? [[String: Any]])
        #expect(errors.compactMap { $0["workspace_id"] as? String } == ["native-offline", "legacy-offline"])
    }

}
