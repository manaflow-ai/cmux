import AppKit
import CMUXAgentLaunch
import CmuxControlSocket
import CmuxCore
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension RemoteResumeBindingTests {
    @Test
    func legacyPersistentAgentHookBindingWithoutCwdPolicyReattachesWithoutReplayingStartupInput() throws {
        let fixture = try makeRelayedFixture()
        var legacySnapshot = try snapshotWithoutRestoreWorkingDirectorySelection(fixture.snapshot)
        let legacyPanelIndex = try #require(
            legacySnapshot.panels.firstIndex { $0.id == fixture.surfaceID }
        )
        var legacyTerminal = try #require(legacySnapshot.panels[legacyPanelIndex].terminal)
        legacyTerminal.agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "session-remote-7989",
            workingDirectory: "/Users/alice/legacy-captured-project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex", "resume", "session-remote-7989"],
                workingDirectory: "/Users/alice/legacy-captured-project"
            )
        )
        legacyTerminal.wasAgentRunning = true
        legacySnapshot.panels[legacyPanelIndex].terminal = legacyTerminal
        let suiteName = "cmux-legacy-remote-resume-cwd-policy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let socketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(socketPath) }

        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        let windowID = UUID()
        let window = makeMainWindow(id: windowID)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            agentSessionAutoResumeDefaults: defaults
        )
        app.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
            for workspace in manager.tabs {
                workspace.teardownAllPanels()
            }
            window.orderOut(nil)
        }

        let restoredWorkspace = try #require(manager.selectedWorkspace)
        let restoredIDs = restoredWorkspace.restoreSessionSnapshot(legacySnapshot)
        let restoredSurfaceID = try #require(restoredIDs[fixture.surfaceID])
        let startupCommand = try #require(
            restoredWorkspace.terminalPanel(for: restoredSurfaceID)?.surface.debugInitialCommand()
        )

        #expect(startupCommand.contains("ssh-pty-attach"), "\(startupCommand)")
        #expect(startupCommand.contains("--require-existing"), "\(startupCommand)")
        let remoteCommand = try decodedRemoteCommand(from: startupCommand)
        #expect(remoteCommand.contains("export CMUX_SOCKET_PATH=127.0.0.1:\(fixture.relayPort)"), "\(remoteCommand)")
        #expect(try decodedInitialCommandIfPresent(from: remoteCommand) == nil)
        #expect(!remoteCommand.contains("session-remote-7989"), "\(remoteCommand)")
        #expect(!remoteCommand.contains("REMOTE_FLAG"), "\(remoteCommand)")

        let migratedBinding = try #require(
            restoredWorkspace.surfaceResumeBinding(panelId: restoredSurfaceID)
        )
        #expect(migratedBinding.restoreWorkingDirectorySelection == .unavailable)
        #expect(migratedBinding.command.isEmpty)

        let resolution = TerminalController.shared.controlSurfaceResumeGet(
            routing: ControlRoutingSelectors(
                hasWindowIDParam: true,
                windowID: windowID,
                groupID: nil,
                workspaceID: restoredWorkspace.id,
                surfaceID: restoredSurfaceID,
                paneID: nil
            ),
            explicitTargetID: restoredSurfaceID,
            hasResolvedWindowID: true,
            claimCheckpointID: nil,
            claimSource: nil,
            claimUpdatedAt: nil
        )
        guard case .result(let snapshot) = resolution else {
            Issue.record("surface.resume.get failed: \(resolution)")
            return
        }
        #expect(snapshot.restoreRecord == nil)
    }

    @Test
    func authenticatedPersistentSSHRefreshOverridesStaleUnavailablePolicy() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let surfaceID = try #require(workspace.focusedPanelId)
        let sessionID = "remote-refresh-session"
        let staleDirectory = "/srv/stale-project"
        let trustedDirectory = "/srv/current-project"
        let context = SurfaceResumeRemoteContext(
            workspaceID: workspace.id,
            surfaceID: surfaceID,
            persistentPTYSessionID: Workspace.defaultSSHPTYSessionID(
                workspaceId: workspace.id,
                panelId: surfaceID
            )
        )

        workspace.surfaceResumeBindingsByPanelId[surfaceID] = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID)",
            cwd: staleDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            restoreWorkingDirectorySelection: .unavailable,
            autoResume: true,
            launchFlavor: .persistentSSH(context)
        )
        workspace.setRestoredAgentSnapshotForTesting(SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: staleDirectory,
            launchCommand: nil,
            restoreWorkingDirectorySelection: .unavailable
        ), panelId: surfaceID)

        let authenticatedRefresh = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID)",
            cwd: trustedDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true
        ).registeredForPersistentSSH(context)
        #expect(authenticatedRefresh.restoreWorkingDirectorySelection == .exact(trustedDirectory))
        #expect(workspace.setSurfaceResumeBinding(authenticatedRefresh, panelId: surfaceID))

        let retained = try #require(workspace.surfaceResumeBinding(panelId: surfaceID))
        #expect(retained.restoreWorkingDirectorySelection == .exact(trustedDirectory))
        #expect(retained.cwd == trustedDirectory)
        #expect(retained.command.contains(sessionID))

        let retainedAgent = try #require(
            workspace.restoredAgentSnapshotsByPanelId[surfaceID]
        )
        #expect(retainedAgent.restoreWorkingDirectorySelection == .exact(trustedDirectory))
        #expect(retainedAgent.workingDirectory == trustedDirectory)
        #expect(retainedAgent.resumeCommand?.contains(trustedDirectory) == true)
    }

    func snapshotWithoutRestoreWorkingDirectorySelection(
        _ snapshot: SessionWorkspaceSnapshot
    ) throws -> SessionWorkspaceSnapshot {
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var panels = try #require(object["panels"] as? [[String: Any]])
        let panelIndex = try #require(panels.firstIndex { $0["terminal"] != nil })
        var panel = panels[panelIndex]
        var terminal = try #require(panel["terminal"] as? [String: Any])
        var binding = try #require(terminal["resumeBinding"] as? [String: Any])
        binding.removeValue(forKey: "restoreWorkingDirectorySelection")
        terminal["resumeBinding"] = binding
        panel["terminal"] = terminal
        panels[panelIndex] = panel
        object["panels"] = panels
        return try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    func decodedInitialCommandIfPresent(from bootstrap: String) throws -> String? {
        guard let payloadLine = bootstrap.split(separator: "\n").first(where: { line in
            line.contains("printf %s '") && line.contains("> \"$cmux_initial_command_tmp\"")
        }) else {
            return nil
        }
        let prefixRange = try #require(payloadLine.range(of: "printf %s '"))
        let encodedSuffix = payloadLine[prefixRange.upperBound...]
        let closingQuote = try #require(encodedSuffix.firstIndex(of: "'"))
        let encodedCommand = String(encodedSuffix[..<closingQuote])
        let data = try #require(Data(base64Encoded: encodedCommand))
        return try #require(String(data: data, encoding: .utf8))
    }

}
