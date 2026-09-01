import AppKit
import CmuxCore
import CmuxControlSocket
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises the controller boundary used by the remote Claude Teams tmux shim.
/// The fixture deliberately uses a remote-only path so a local Ghostty launch
/// cannot accidentally satisfy the assertions.
@MainActor
@Suite(.serialized)
struct RemoteClaudeTeamsRespawnRoutingTests {
    private let remoteWorkingDirectory = "/data00/cmux-11049/remote-only/project"
    private let remoteExecutable = "/opt/cmux-11049/remote-only/bin/claude"

    @Test
    func splitThenRespawnKeepsTeammateOnRemotePTYOwner() throws {
        let fixture = try Fixture(remoteTerminalTransport: .ssh)
        defer { fixture.tearDown() }

        let split = TerminalController.shared.controlSurfaceSplit(
            routing: fixture.routing(surfaceID: fixture.panelID),
            inputs: ControlSurfaceSplitInputs(
                directionRaw: "right",
                typeRaw: "terminal",
                urlRaw: nil,
                requestedSourceSurfaceID: fixture.panelID,
                workingDirectory: remoteWorkingDirectory,
                initialCommand: nil,
                tmuxStartCommand: nil,
                remotePTYSessionID: nil,
                remoteContextRaw: nil,
                startupEnvironment: [:],
                clientUnsupportedRemoteTmuxOptions: [],
                requestedFocus: false,
                initialDividerPosition: nil
            )
        )
        guard case .created(_, _, _, let childID, _) = split else {
            Issue.record("Expected the placeholder split to be created: \(split)")
            return
        }
        #expect(fixture.workspace.isRemoteTerminalSurface(childID))

        let oldSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: fixture.workspace.id,
            panelId: childID
        )
        let rawTeammateCommand =
            "cd \(remoteWorkingDirectory) && env CLAUDECODE=1 \(remoteExecutable) --agent-id teammate@team"
        let result = TerminalController.shared.controlSurfaceRespawn(
            routing: fixture.routing(surfaceID: childID),
            inputs: fixture.respawnInputs(
                surfaceID: childID,
                command: rawTeammateCommand,
                tmuxStartCommand: rawTeammateCommand,
                workingDirectory: remoteWorkingDirectory
            )
        )
        guard case .respawned = result else {
            Issue.record("Expected remote teammate respawn to succeed: \(result)")
            return
        }

        let replacement = try #require(fixture.workspace.terminalPanel(for: childID))
        let launchCommand = try #require(replacement.surface.debugInitialCommand())
        let replacementSessionID = try #require(
            fixture.workspace.remotePTYSessionIDsByPanelId[childID]
        )

        // The local surface must launch only the bridge; the raw remote command
        // belongs to the daemon-owned PTY on the remote host.
        #expect(launchCommand.contains("ssh-pty-attach"))
        #expect(!launchCommand.contains(rawTeammateCommand))
        #expect(replacement.surface.debugTmuxStartCommand() == rawTeammateCommand)
        #expect(replacement.surface.requestedWorkingDirectory != remoteWorkingDirectory)
        #expect(
            replacement.surface.requestedWorkingDirectory.map {
                FileManager.default.fileExists(atPath: $0)
            } == true
        )

        // A respawn is a new remote session generation, while the logical
        // surface remains tracked and its prior generation is no longer mapped.
        #expect(replacementSessionID != oldSessionID)
        #expect(Workspace.parsedDefaultSSHPTYSessionID(replacementSessionID) != nil)
        #expect(fixture.workspace.activeRemoteTerminalSurfaceIds.contains(childID))
    }

    @Test
    func disconnectedPersistentSSHStillUsesRemoteBridge() throws {
        let fixture = try Fixture(remoteTerminalTransport: .ssh)
        defer { fixture.tearDown() }
        fixture.workspace.remoteConnectionState = .disconnected
        fixture.workspace.remoteControllerConnectionState = .disconnected
        fixture.workspace.remoteSessionController = nil

        let raw = "cd \(remoteWorkingDirectory) && \(remoteExecutable) --agent-id disconnected"
        let result = TerminalController.shared.controlSurfaceRespawn(
            routing: fixture.routing(surfaceID: fixture.panelID),
            inputs: fixture.respawnInputs(
                surfaceID: fixture.panelID,
                command: raw,
                tmuxStartCommand: raw,
                workingDirectory: remoteWorkingDirectory
            )
        )
        guard case .respawned = result else {
            Issue.record("Expected disconnected persistent SSH respawn to be accepted: \(result)")
            return
        }
        let replacement = try #require(fixture.workspace.terminalPanel(for: fixture.panelID))
        #expect(replacement.surface.debugInitialCommand()?.contains("ssh-pty-attach") == true)
        #expect(fixture.workspace.activeRemoteTerminalSurfaceIds.contains(fixture.panelID))
    }

    @Test
    func localSurfaceStillRespawnsLocally() throws {
        let fixture = try Fixture(remoteTerminalTransport: nil)
        defer { fixture.tearDown() }

        let raw = "echo local-command"
        let result = TerminalController.shared.controlSurfaceRespawn(
            routing: fixture.routing(surfaceID: fixture.panelID),
            inputs: fixture.respawnInputs(
                surfaceID: fixture.panelID,
                command: raw,
                tmuxStartCommand: raw,
                workingDirectory: "/tmp"
            )
        )
        guard case .respawned = result else {
            Issue.record("Expected local respawn to succeed: \(result)")
            return
        }
        let replacement = try #require(fixture.workspace.terminalPanel(for: fixture.panelID))
        #expect(replacement.surface.debugInitialCommand() == raw)
        #expect(!fixture.workspace.isRemoteTerminalSurface(fixture.panelID))
        #expect(fixture.workspace.remotePTYSessionIDsByPanelId[fixture.panelID] == nil)
    }

    @Test
    func untrackedSurfaceInRemoteWorkspaceStillRespawnsLocally() throws {
        let fixture = try Fixture(remoteTerminalTransport: .ssh)
        defer { fixture.tearDown() }
        let paneID = try #require(fixture.workspace.paneId(forPanelId: fixture.panelID))
        let localPanel = try #require(
            fixture.workspace.newTerminalSurface(
                inPane: paneID,
                focus: false,
                suppressWorkspaceRemoteStartupCommand: true
            )
        )
        #expect(!fixture.workspace.isRemoteTerminalSurface(localPanel.id))

        let raw = "echo local-untracked"
        let result = TerminalController.shared.controlSurfaceRespawn(
            routing: fixture.routing(surfaceID: localPanel.id),
            inputs: fixture.respawnInputs(
                surfaceID: localPanel.id,
                command: raw,
                tmuxStartCommand: raw,
                workingDirectory: "/tmp"
            )
        )
        guard case .respawned = result else {
            Issue.record("Expected untracked local respawn to succeed: \(result)")
            return
        }
        let replacement = try #require(fixture.workspace.terminalPanel(for: localPanel.id))
        #expect(replacement.surface.debugInitialCommand() == raw)
        #expect(!fixture.workspace.isRemoteTerminalSurface(localPanel.id))
        #expect(fixture.workspace.remotePTYSessionIDsByPanelId[localPanel.id] == nil)
    }

    @Test
    func unsupportedRemoteTransportFailsClosedInsteadOfLaunchingLocally() throws {
        let fixture = try Fixture(remoteTerminalTransport: .mosh)
        defer { fixture.tearDown() }

        let raw = "cd \(remoteWorkingDirectory) && \(remoteExecutable) --agent-id mosh"
        let result = TerminalController.shared.controlSurfaceRespawn(
            routing: fixture.routing(surfaceID: fixture.panelID),
            inputs: fixture.respawnInputs(
                surfaceID: fixture.panelID,
                command: raw,
                tmuxStartCommand: raw,
                workingDirectory: remoteWorkingDirectory
            )
        )

        #expect(result == .respawnFailed(fixture.panelID))
        #expect(fixture.workspace.terminalPanel(for: fixture.panelID) != nil)
        #expect(fixture.workspace.activeRemoteTerminalSurfaceIds.contains(fixture.panelID))
    }

    @Test
    func disconnectedRespawnParksPreviousSessionCleanupUntilDrain() throws {
        let fixture = try Fixture(remoteTerminalTransport: .ssh)
        defer { fixture.tearDown() }
        fixture.workspace.remoteConnectionState = .disconnected
        fixture.workspace.remoteControllerConnectionState = .disconnected
        fixture.workspace.remoteSessionController = nil

        let oldSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: fixture.workspace.id,
            panelId: fixture.panelID
        )
        let raw = "cd \(remoteWorkingDirectory) && \(remoteExecutable) --agent-id parked"
        let result = TerminalController.shared.controlSurfaceRespawn(
            routing: fixture.routing(surfaceID: fixture.panelID),
            inputs: fixture.respawnInputs(
                surfaceID: fixture.panelID,
                command: raw,
                tmuxStartCommand: raw,
                workingDirectory: remoteWorkingDirectory
            )
        )
        guard case .respawned = result else {
            Issue.record("Expected disconnected respawn to succeed: \(result)")
            return
        }

        // No controller: the replaced daemon session must be parked, not
        // dropped, and it must stay bound to the persistent-PTY identity
        // that owned it so a later host change cannot drain it elsewhere.
        #expect(Array(fixture.workspace.pendingRemotePTYSessionCleanups.keys) == [oldSessionID])
        let parkedIdentity = try #require(
            fixture.workspace.pendingRemotePTYSessionCleanups[oldSessionID]
        )
        let currentConfiguration = try #require(fixture.workspace.remoteConfiguration)
        #expect(parkedIdentity.hasSamePersistentPTYIdentity(as: currentConfiguration))

        // First drain failure re-queues; the next drain closes exactly once
        // and a further drain has nothing left to do.
        var closed: [String] = []
        var failNextClose = true
        fixture.workspace.remotePTYSessionCloseForTesting = { sessionID in
            if failNextClose {
                failNextClose = false
                throw NSError(domain: "cmux-11049-test", code: 1)
            }
            closed.append(sessionID)
        }
        fixture.workspace.drainPendingRemotePTYSessionCleanups()
        #expect(closed.isEmpty)
        #expect(Array(fixture.workspace.pendingRemotePTYSessionCleanups.keys) == [oldSessionID])
        fixture.workspace.drainPendingRemotePTYSessionCleanups()
        #expect(closed == [oldSessionID])
        #expect(fixture.workspace.pendingRemotePTYSessionCleanups.isEmpty)
        fixture.workspace.drainPendingRemotePTYSessionCleanups()
        #expect(closed == [oldSessionID])
    }

    @Test
    func endedPersistentRemotePTYStillRespawnsRemotely() throws {
        let fixture = try Fixture(remoteTerminalTransport: .ssh)
        defer { fixture.tearDown() }
        let sessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: fixture.workspace.id,
            panelId: fixture.panelID
        )
        let outcome = fixture.workspace.markRemotePTYAttachEnded(
            surfaceId: fixture.panelID,
            sessionID: sessionID
        )
        #expect(outcome.clearedRemotePTYSession)
        #expect(!fixture.workspace.activeRemoteTerminalSurfaceIds.contains(fixture.panelID))
        #expect(fixture.workspace.endedPersistentRemotePTYAttachSurfaceIds.contains(fixture.panelID))

        let raw = "cd \(remoteWorkingDirectory) && \(remoteExecutable) --agent-id ended"
        let result = TerminalController.shared.controlSurfaceRespawn(
            routing: fixture.routing(surfaceID: fixture.panelID),
            inputs: fixture.respawnInputs(
                surfaceID: fixture.panelID,
                command: raw,
                tmuxStartCommand: raw,
                workingDirectory: remoteWorkingDirectory
            )
        )
        guard case .respawned = result else {
            Issue.record("Expected an ended persistent PTY to respawn remotely: \(result)")
            return
        }
        let replacement = try #require(fixture.workspace.terminalPanel(for: fixture.panelID))
        let launchCommand = try #require(replacement.surface.debugInitialCommand())
        #expect(launchCommand.contains("ssh-pty-attach"))
        #expect(!launchCommand.contains(raw))
        #expect(fixture.workspace.activeRemoteTerminalSurfaceIds.contains(fixture.panelID))
        #expect(!fixture.workspace.endedPersistentRemotePTYAttachSurfaceIds.contains(fixture.panelID))
    }

    @Test
    func respawnPlanHonorsExplicitRemoteWorkingDirectory() throws {
        let fixture = try Fixture(remoteTerminalTransport: .ssh)
        defer { fixture.tearDown() }
        let plan = try #require(fixture.workspace.remotePTYRespawnPlan(
            panelId: fixture.panelID,
            rawCommand: "claude --agent-id t1@team",
            remoteWorkingDirectory: "/data00/it's here"
        ))
        #expect(plan.remoteCommand == "cd '/data00/it'\\''s here' && claude --agent-id t1@team")
        #expect(plan.rawCommand == "claude --agent-id t1@team")
        #expect(plan.bridgeCommand.contains("ssh-pty-attach"))

        let bare = try #require(fixture.workspace.remotePTYRespawnPlan(
            panelId: fixture.panelID,
            rawCommand: "claude --agent-id t1@team"
        ))
        #expect(bare.remoteCommand == "claude --agent-id t1@team")
    }

    @MainActor
    private struct Fixture {
        let appDelegate: AppDelegate
        let previousAppDelegate: AppDelegate?
        let previousTabManager: TabManager?
        let windowID: UUID
        let workspace: Workspace
        let panelID: UUID

        init(remoteTerminalTransport: WorkspaceRemoteTerminalTransport?) throws {
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
                if let remoteTerminalTransport {
                    let configuration = Self.remoteConfiguration(
                        remoteTerminalTransport: remoteTerminalTransport
                    )
                    try #require(
                        resolvedWorkspace.configureRemoteConnection(configuration, autoConnect: false)
                    )
                    resolvedWorkspace.panelDirectories[resolvedPanelID] = "/data00/cmux-11049/remote-only/leader"
                    resolvedWorkspace.trackRemoteTerminalSurface(resolvedPanelID)
                }
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

        private static func remoteConfiguration(
            remoteTerminalTransport: WorkspaceRemoteTerminalTransport
        ) -> WorkspaceRemoteConfiguration {
            WorkspaceRemoteConfiguration(
                transport: .ssh,
                terminalTransport: remoteTerminalTransport,
                destination: "tiny@remote-only",
                port: 22,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 22049,
                relayID: "cmux-11049",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: nil,
                terminalStartupCommand: "cmux remote-shell",
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "cmux-11049",
                skipDaemonBootstrap: false
            )
        }

        func routing(surfaceID: UUID) -> ControlRoutingSelectors {
            ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: workspace.id,
                surfaceID: surfaceID,
                paneID: nil
            )
        }

        func respawnInputs(
            surfaceID: UUID,
            command: String,
            tmuxStartCommand: String,
            workingDirectory: String
        ) -> ControlSurfaceRespawnInputs {
            ControlSurfaceRespawnInputs(
                command: command,
                tmuxStartCommand: tmuxStartCommand,
                workingDirectory: workingDirectory,
                hasSurfaceIDParam: true,
                requestedSurfaceID: surfaceID,
                hasFocusParam: false,
                requestedFocus: false
            )
        }

        func tearDown() {
            workspace.disconnectRemoteConnection(clearConfiguration: true)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            appDelegate.tabManager = previousTabManager
            AppDelegate.shared = previousAppDelegate
        }
    }
}
