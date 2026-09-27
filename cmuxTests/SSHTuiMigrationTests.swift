import CmuxCloud
import CmuxCloudTui
import CmuxCore
import CmuxFoundation
import CmuxSurfaceCatalogModel
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

    @Test("The carrier authenticates in batch mode and keeps reconnecting after startup")
    func carrierKeepsUnlimitedBatchReconnects() {
        let arguments = SSHTuiConnection(configuration: configuration()).arguments(
            stateDirectory: "/tmp/cmux-tui-client",
            deviceName: "test"
        )
        let sshArguments = arguments.indices.compactMap { index -> String? in
            guard index > 0, arguments[index - 1] == "--ssh-arg" else { return nil }
            return arguments[index]
        }
        for option in ["BatchMode=yes", "RequestTTY=no", "RemoteCommand=none"] {
            #expect(zip(sshArguments, sshArguments.dropFirst()).contains { $0 == ("-o", option) })
        }
        // Reconnect limits apply to the whole carrier lifetime, so capping them
        // would end SSH persistence after the first network drop.
        for limit in ["--reconnect-attempts", "--reconnect-attempt-timeout-ms", "--connect-timeout-seconds"] {
            #expect(!arguments.contains(limit))
        }
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

    @Test("Legacy persistent SSH snapshots are not claimed by the TUI owner")
    func legacySnapshotDoesNotBecomeTuiSession() throws {
        let legacy = SessionRemoteWorkspaceSnapshot(transport: .ssh, destination: "fixture@host",
            preserveAfterTerminalExit: true, relayPort: 1234, persistentDaemonSlot: "legacy-owned")
        #expect(legacy.tuiSSHConfiguration(agentSocketPath: nil) == nil)
        let blocked = try #require(legacy.workspaceConfiguration())
        #expect(blocked.terminalStartupCommand == nil)
        #expect(blocked.sessionSnapshot() == legacy)
        #expect(blocked.scopedToOwnerWorkspace(UUID()).sessionSnapshot() == legacy)
        #expect(blocked.withSSHControlMasterLeaseGeneration(UUID()).sessionSnapshot() == legacy)

    }

    @Test("A legacy persistent SSH snapshot running a named tmux session reattaches it through cmux-tui")
    func legacyTmuxSnapshotReattachesItsTmuxSession() throws {
        // The remote block 0.64.25 wrote for `cmux ssh` workspaces with a tmux
        // profile: relay port and daemon slot, no session owner.
        let json = Data("""
        {"destination": "fixture-host", "persistentDaemonSlot": "ssh-410b76b4-e7ea-4db1-8394-9d06bfc19b5c",
         "preserveAfterTerminalExit": true, "relayPort": 52206, "skipDaemonBootstrap": false,
         "sshOptions": ["EscapeChar=none", "EnableEscapeCommandline=no", "StrictHostKeyChecking=accept-new"],
         "terminalProfile": {"kind": "tmux", "tmuxSessionName": "cc-fixture"},
         "terminalTransport": "ssh", "transport": "ssh"}
        """.utf8)
        let legacy = try JSONDecoder().decode(SessionRemoteWorkspaceSnapshot.self, from: json)
        #expect(legacy.sshSessionOwner == nil)

        let restored = try #require(legacy.workspaceConfiguration())
        #expect(restored.routesThroughSSHTui)
        #expect(restored.restoredSSHSession == legacy)
        #expect(restored.destination == "fixture-host")
        #expect(restored.terminalProfile.tmuxSessionName == "cc-fixture")
        #expect(restored.terminalStartupCommand == nil)
        #expect(restored.relayPort == nil)
        #expect(restored.preserveAfterTerminalExit)
        // The command can return a created path even after a dead child; retain
        // the legacy descriptor until a future explicit liveness acknowledgment.
        let tmux = try #require(WorkspaceRemoteTerminalProfile(kind: .tmux, tmuxSessionName: "cc-fixture"))
        #expect(SSHTuiConnection(configuration: restored).shellCommand.suffix(3) == ["attach-session", "-t", "=cc-fixture"])

        // Keep the durable legacy descriptor across saves until a real process
        // liveness acknowledgment exists; this avoids claiming a dead attach.
        let resaved = try #require(restored.sessionSnapshot())
        #expect(resaved.sshSessionOwner == nil)
        #expect(resaved.relayPort == 52206)
        #expect(resaved.persistentDaemonSlot == "ssh-410b76b4-e7ea-4db1-8394-9d06bfc19b5c")
        #expect(resaved.terminalProfile == tmux)
    }

    @Test("Legacy tmux restore keeps its descriptor and attaches only to the existing session", arguments: [false, true])
    func legacyTmuxRestoreRequiresExistingSession(omitsTerminalTransport: Bool) throws {
        let json = Data("""
        {"destination": "fixture-host", "persistentDaemonSlot": "legacy-slot",
         "preserveAfterTerminalExit": true, "relayPort": 52206, "sshOptions": [],
         "terminalProfile": {"kind": "tmux", "tmuxSessionName": "cc-fixture"},
         "terminalTransport": "ssh", "transport": "ssh"}
        """.utf8)
        var fields = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        if omitsTerminalTransport { fields.removeValue(forKey: "terminalTransport") }
        let legacy = try JSONDecoder().decode(
            SessionRemoteWorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: fields)
        )
        let restored = try #require(legacy.workspaceConfiguration())
        let tmux = try #require(WorkspaceRemoteTerminalProfile(kind: .tmux, tmuxSessionName: "cc-fixture"))
        #expect(restored.restoredSSHSession == legacy)
        let connection = SSHTuiConnection(configuration: restored)
        #expect(connection.shellCommand.suffix(3) == ["attach-session", "-t", "=cc-fixture"])

        // A failed attach must keep the legacy descriptor, rather than claiming
        // cmux-tui ownership before the remote session was proven.
        let failed = try #require(restored.sessionSnapshot())
        #expect(failed.sshSessionOwner == nil)
        #expect(failed.persistentDaemonSlot == "legacy-slot")
        #expect(failed.relayPort == 52206)
        let roundTripped = try #require(try JSONDecoder().decode(
            SessionRemoteWorkspaceSnapshot.self, from: JSONEncoder().encode(failed)
        ).workspaceConfiguration())
        #expect(roundTripped.restoredSSHSession == failed)
        #expect(SSHTuiConnection(configuration: roundTripped).id == connection.id)
        #expect(SSHTuiConnection(configuration: roundTripped).shellCommand.suffix(3) == ["attach-session", "-t", "=cc-fixture"])

        let fresh = WorkspaceRemoteConfiguration(terminalProfile: tmux, destination: "fixture-host", port: nil,
            identityFile: nil, sshOptions: [], localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, preserveAfterTerminalExit: true)
        #expect(SSHTuiConnection(configuration: fresh).shellCommand == tmux.remoteCommandArguments)
    }

    // Covers the two attach helpers: the title attach enqueues as a rename before
    // binding, and the create request, whose fingerprint must not depend on it.
    @MainActor
    @Test("An SSH attach publishes the local workspace title to the remote workspace it creates")
    func attachPublishesLocalTitleToRemoteWorkspace() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let untitled = SSHTuiWorkspaceCoordinator.remoteWorkspaceCreationRequest(for: workspace, socketPath: "/tmp/fixture.sock")
        #expect(untitled.operation == "workspace.create")
        #expect(untitled.params["initial_content"] as? String == "empty")
        #expect(SSHTuiWorkspaceCoordinator.remoteWorkspaceTitleToPublish(for: workspace) == nil)

        // `cmux ssh --name`, `cmux mosh-tmux --name`, and a restored user title all
        // reach attach as the local custom title. The daemon graph owns the name
        // once the workspace is bound, so attach must publish the title or the
        // daemon default (`workspace-N`) replaces it.
        #expect(workspace.setCustomTitle("s655 @big-red", source: .user))
        #expect(SSHTuiWorkspaceCoordinator.remoteWorkspaceTitleToPublish(for: workspace) == "s655 @big-red")
        // The create itself stays unnamed and identical across title edits, so a
        // replay of the per-workspace idempotency key never conflicts.
        let titled = SSHTuiWorkspaceCoordinator.remoteWorkspaceCreationRequest(for: workspace, socketPath: "/tmp/fixture.sock")
        #expect(titled.params["name"] == nil)
        #expect(titled.parameters == untitled.parameters)
        #expect(titled.idempotencyKey == untitled.idempotencyKey)

        // Auto titles are derived locally, and a title over the daemon's
        // 1024-byte limit would fail the rename; neither is published.
        let automatic = Workspace()
        defer { automatic.teardownAllPanels() }
        #expect(automatic.setCustomTitle("derived-from-cwd", source: .auto))
        #expect(SSHTuiWorkspaceCoordinator.remoteWorkspaceTitleToPublish(for: automatic) == nil)
        #expect(workspace.setCustomTitle(String(repeating: "x", count: 1025), source: .user))
        #expect(SSHTuiWorkspaceCoordinator.remoteWorkspaceTitleToPublish(for: workspace) == nil)
    }

    @Test("Managed SSH snapshot serialization records its session owner")
    func managedSnapshotRecordsOwner() throws {
        let snapshot = try #require(configuration().sessionSnapshot())
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(object["sshSessionOwner"] as? String == "cmux-tui")
    }

    @MainActor
    @Test("A legacy relay configuration keeps its relay lifecycle and startup command")
    func legacyRelayConfigurationIsNotClaimedByCmuxTui() {
        let native = configuration()
        #expect(native.routesThroughSSHTui)
        // The shape the CLI's no-TTY `cmux ssh` path sends to workspace.remote.configure.
        let legacy = WorkspaceRemoteConfiguration(
            destination: "alice@example.invalid", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: 64007, relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64), localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh -T alice@example.invalid", preserveAfterTerminalExit: false
        )
        #expect(!legacy.routesThroughSSHTui)
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        #expect(workspace.configureRemoteConnection(legacy, autoConnect: false))
        #expect(!workspace.usesSSHTui)
        #expect(workspace.effectiveRemoteTerminalStartupCommand(from: workspace.remoteConfiguration) == "ssh -T alice@example.invalid")
        // Only cmux-tui-owned persistent sessions drop the startup command; a
        // persistent relay configuration still runs its own.
        let persistentLegacy = WorkspaceRemoteConfiguration(
            destination: "alice@example.invalid", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: 64007, relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64), localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh-pty-attach", preserveAfterTerminalExit: true
        )
        #expect(workspace.effectiveRemoteTerminalStartupCommand(from: persistentLegacy) == "ssh-pty-attach")
        #expect(workspace.effectiveRemoteTerminalStartupCommand(from: native) == nil)
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
    @Test("Pending native SSH projections remain remote until removed")
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

    @Test("Loopback links in SSH terminals retain remote routing")
    func sshLoopbackLinkUsesItsMachineCarrier() throws {
        let resource = SurfaceResource(
            id: .init(machine: .ssh("fixture"), kind: .terminal, key: "term_remote"),
            title: "shell", detail: "/home/alice", lifecycle: .running,
            agent: nil, remoteWorkspace: nil, port: nil, url: nil
        )
        let url = try #require(URL(string: "http://localhost:3000/project?view=source"))
        let target = try #require(CmuxTuiSurfaceProvider.cloudTerminalLinkTarget(
            url: url, resource: resource, privateAddress: "127.0.0.1"
        ))
        #expect(target.url.port == 3000)
        #expect(target.url.path == "/project")
        #expect(target.url.query == "view=source")
    }

    @Test("SSH port previews admit remote loopback without widening Cloud routes")
    func sshPortPreviewRetainsCarrierOwnership() {
        let resource = CmuxTuiSnapshotParser.portBrowser(machine: .ssh("fixture"), port: 3000)
        #expect(CloudPortRoutePlan.plan(resource: resource, privateAddress: "127.0.0.1")
            == .privateDirect(remoteURL: "http://127.0.0.1:3000"))
        let cloud = CmuxTuiSnapshotParser.portBrowser(machine: .cloud("fixture"), port: 3000)
        guard case .unsupported = CloudPortRoutePlan.plan(resource: cloud, privateAddress: "127.0.0.1") else {
            Issue.record("Cloud must not acquire an SSH loopback route")
            return
        }
    }

    @Test("An unconfirmed SSH graph cannot publish its saved remote working directory")
    @MainActor
    func unconfirmedSSHDirectoryRemainsUntrusted() {
        let resource = SurfaceResource(
            id: .init(machine: .ssh("fixture"), kind: .terminal, key: "term_remote"),
            title: "shell", detail: "/home/alice", lifecycle: .running,
            agent: nil, remoteWorkspace: nil, port: nil, url: nil
        )
        #expect(SurfaceCatalog().resourceForPresentation(resource).detail == nil)
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
        #expect(workspace.remotePTYRespawnRouting(panelId: panelID) == .unsupportedRemote)
        #expect(workspace.respawnTerminalSurface(panelId: panelID, command: "printf remote-only") == nil)
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
        // Projection validates its destination through Workspace.liveWorkspace, so
        // the workspace must belong to the app's TabManager. A detached Workspace()
        // fails with destinationNotFound and the provider never materializes.
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalTabManager = appDelegate.tabManager
        let manager = originalTabManager ?? TabManager()
        appDelegate.tabManager = manager
        let workspace = manager.addWorkspace(select: false)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) { manager.closeWorkspace(workspace, recordHistory: false) }
            appDelegate.tabManager = originalTabManager
        }
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

    @Test("Reconnect for an unrelated pane cannot restart a native SSH workspace")
    @MainActor
    func unrelatedSurfaceReconnectDoesNotRestartSSHWorkspace() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.remoteConfiguration = configuration()
        let localPanelID = try #require(workspace.focusedPanelId)
        #expect(workspace.usesSSHTui)
        #expect(workspace.reconnectRemoteConnection(surfaceId: localPanelID) == false)
        #expect(workspace.reconnectRemoteConnection(surfaceId: UUID()) == false)
        #expect(workspace.sshTuiConnectionAttemptID == nil)
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


    @Test("The carrier asks the host to install the requested agent hooks")
    func carrierRequestsAgentHooks() throws {
        var carrier = SSHTuiConnection(configuration: configuration())
        #expect(!carrier.arguments(stateDirectory: "/tmp/state", deviceName: "test").contains("--agent-hooks"))
        carrier.agentHookProviders = ["claude", "codex"]
        let arguments = carrier.arguments(stateDirectory: "/tmp/state", deviceName: "test")
        let index = try #require(arguments.firstIndex(of: "--agent-hooks"))
        #expect(arguments[index + 1] == "claude,codex")
        #expect(carrier.id == SSHTuiConnection(configuration: configuration()).id)
    }

    @Test("Integrations hook toggles choose the SSH agent hook providers")
    func agentHookProvidersFollowIntegrationToggles() throws {
        let suite = "SSHTuiMigrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SSHTuiConnection.agentHookProviders(defaults: defaults) == ["claude", "codex"])
        defaults.set(false, forKey: "claudeCodeHooksEnabled")
        #expect(SSHTuiConnection.agentHookProviders(defaults: defaults) == ["codex"])
        defaults.set(false, forKey: "codexHooksEnabled")
        #expect(SSHTuiConnection.agentHookProviders(defaults: defaults).isEmpty)
    }
}
