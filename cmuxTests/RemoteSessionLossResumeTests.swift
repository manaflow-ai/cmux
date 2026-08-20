import AppKit
import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `Workspace.remoteContinueResumeCommandAfterSessionLoss` (#7989): the
/// policy seam that turns a daemon foreground tombstone into a hookless
/// directory-scoped continue command after a persistent-SSH session died.
/// Every case is hermetic — value-injected `remoteConfiguration`, private
/// defaults suites, no sockets, no subprocesses, no shared fixtures.
@Suite
@MainActor
struct RemoteSessionLossResumeTests {
    private let relayPort = 64_121

    @Test
    func sessionLossSynthesizesContinueFromDaemonForegroundTombstone() throws {
        let suiteName = "cmux-session-loss-resume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.remoteConfiguration = remoteConfiguration().scopedToOwnerWorkspace(workspace.id)
        let sessionID = Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panel.id)

        let command = try #require(workspace.remoteContinueResumeCommandAfterSessionLoss(
            panelId: panel.id,
            persistentPTYSessionID: sessionID,
            foregroundCommand: "/home/dev/.local/bin/claude",
            foregroundCwd: "/home/dev/resume lab"
        ))

        #expect(command.contains("export CMUX_SOCKET_PATH=127.0.0.1:\(relayPort)"), "\(command)")
        let initialCommand = try decodedInitialCommand(from: command)
        #expect(initialCommand.contains("claude --continue || claude"), "\(initialCommand)")
        #expect(initialCommand.contains("resume lab"), "\(initialCommand)")

        let binding = try #require(workspace.surfaceResumeBinding(panelId: panel.id))
        #expect(binding.isRemoteSynthesized)
        #expect(binding.kind == "claude")
        #expect(binding.cwd == "/home/dev/resume lab")
        guard case .persistentSSH(let context) = binding.launchFlavor else {
            Issue.record("expected a persistentSSH launch flavor, got \(binding.launchFlavor)")
            return
        }
        #expect(context.matches(
            workspaceID: workspace.id,
            surfaceID: panel.id,
            persistentPTYSessionID: sessionID
        ))
    }

    @Test
    func sessionLossSynthesizesCodexResumeFromDaemonForegroundTombstone() throws {
        let suiteName = "cmux-session-loss-codex-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.remoteConfiguration = remoteConfiguration().scopedToOwnerWorkspace(workspace.id)

        let command = try #require(workspace.remoteContinueResumeCommandAfterSessionLoss(
            panelId: panel.id,
            persistentPTYSessionID: "ssh-session-codex",
            foregroundCommand: "codex",
            foregroundCwd: "/srv/codex work"
        ))

        let initialCommand = try decodedInitialCommand(from: command)
        #expect(initialCommand.contains("codex resume --last || codex"), "\(initialCommand)")
        let binding = try #require(workspace.surfaceResumeBinding(panelId: panel.id))
        #expect(binding.kind == "codex")
        #expect(binding.isRemoteSynthesized)
    }

    @Test(arguments: ["zsh", "bash", "-zsh", "vim", "python3", ""])
    func sessionLossNeverSynthesizesForNonAgentForegrounds(foreground: String) throws {
        let suiteName = "cmux-session-loss-nonagent-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.remoteConfiguration = remoteConfiguration().scopedToOwnerWorkspace(workspace.id)

        let command = workspace.remoteContinueResumeCommandAfterSessionLoss(
            panelId: panel.id,
            persistentPTYSessionID: "ssh-session-nonagent",
            foregroundCommand: foreground,
            foregroundCwd: "/home/dev"
        )

        #expect(command == nil, "\(foreground) must not synthesize a resume command")
        #expect(workspace.surfaceResumeBinding(panelId: panel.id) == nil)
    }

    @Test
    func sessionLossSynthesisHonorsAutoResumeSetting() throws {
        let suiteName = "cmux-session-loss-autoresume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(false, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.remoteConfiguration = remoteConfiguration().scopedToOwnerWorkspace(workspace.id)

        let command = workspace.remoteContinueResumeCommandAfterSessionLoss(
            panelId: panel.id,
            persistentPTYSessionID: "ssh-session-autoresume-off",
            foregroundCommand: "claude",
            foregroundCwd: "/home/dev/project"
        )

        #expect(command == nil)
        #expect(workspace.surfaceResumeBinding(panelId: panel.id) == nil)
    }

    @Test
    func sessionLossSynthesisRequiresPersistentSSHConfiguration() throws {
        let suiteName = "cmux-session-loss-nonpersistent-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.remoteConfiguration = remoteConfiguration(persistentDaemonSlot: nil)
            .scopedToOwnerWorkspace(workspace.id)

        let command = workspace.remoteContinueResumeCommandAfterSessionLoss(
            panelId: panel.id,
            persistentPTYSessionID: "ssh-session-nonpersistent",
            foregroundCommand: "claude",
            foregroundCwd: "/home/dev/project"
        )

        #expect(command == nil)
        #expect(workspace.surfaceResumeBinding(panelId: panel.id) == nil)
    }

    @Test
    func sessionLossSynthesisNeverOverwritesAnExistingBinding() throws {
        let suiteName = "cmux-session-loss-precedence-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.remoteConfiguration = remoteConfiguration().scopedToOwnerWorkspace(workspace.id)
        let existing = try legacyLocalBinding()
        workspace.surfaceResumeBindingsByPanelId[panel.id] = existing

        // A local-flavor binding is not injectable into a persistent-SSH
        // respawn, so the answer is a plain shell — but the tombstone must
        // never displace the more precise existing binding.
        let command = workspace.remoteContinueResumeCommandAfterSessionLoss(
            panelId: panel.id,
            persistentPTYSessionID: "ssh-session-precedence",
            foregroundCommand: "claude",
            foregroundCwd: "/home/dev/project"
        )

        #expect(command == nil)
        let retained = try #require(workspace.surfaceResumeBinding(panelId: panel.id))
        #expect(retained.source == existing.source)
        #expect(!retained.isRemoteSynthesized)
    }

    @Test
    func endedSessionWithoutBindingDelegatesLossToTheWrapper() throws {
        let suiteName = "cmux-session-loss-delegate-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.remoteConfiguration = remoteConfiguration().scopedToOwnerWorkspace(workspace.id)
        let sessionID = Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panel.id)

        _ = workspace.markRemotePTYAttachEnded(surfaceId: panel.id, sessionID: sessionID)
        workspace.markPersistentRemotePTYAttachFailed(surfaceId: panel.id)
        let restarted = workspace.reattachPersistentRemotePTYPanels(
            requestedSurfaceId: panel.id,
            restartEndedSessions: true
        )
        #expect(restarted == [panel.id])

        // With no binding to inject, the replacement wrapper keeps
        // `--require-existing` so its session-lost path owns the
        // tombstone-backed synthesis (#7989) instead of silently starting a
        // plain shell.
        let command = try #require(workspace.terminalPanel(for: panel.id)?.surface.debugInitialCommand())
        #expect(command.contains("--require-existing"), "\(command)")
        #expect(command.contains(sessionID), "\(command)")
    }

    @Test
    func endedSessionWithSynthesizedBindingInjectsWithoutRequireExisting() throws {
        let suiteName = "cmux-session-loss-inject-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.remoteConfiguration = remoteConfiguration().scopedToOwnerWorkspace(workspace.id)
        let sessionID = Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panel.id)
        _ = try #require(workspace.remoteContinueResumeCommandAfterSessionLoss(
            panelId: panel.id,
            persistentPTYSessionID: sessionID,
            foregroundCommand: "claude",
            foregroundCwd: "/home/dev/inject lab"
        ))

        _ = workspace.markRemotePTYAttachEnded(surfaceId: panel.id, sessionID: sessionID)
        workspace.markPersistentRemotePTYAttachFailed(surfaceId: panel.id)
        let restarted = workspace.reattachPersistentRemotePTYPanels(
            requestedSurfaceId: panel.id,
            restartEndedSessions: true
        )
        #expect(restarted == [panel.id])

        let command = try #require(workspace.terminalPanel(for: panel.id)?.surface.debugInitialCommand())
        #expect(!command.contains("--require-existing"), "\(command)")
        let bootstrap = try decodedWrapperRemoteCommand(from: command)
        let initialCommand = try decodedInitialCommand(from: bootstrap)
        #expect(initialCommand.contains("claude --continue || claude"), "\(initialCommand)")
        #expect(initialCommand.contains("inject lab"), "\(initialCommand)")
    }

    private func remoteConfiguration(
        transport: WorkspaceRemoteTransport = .ssh,
        terminalTransport: WorkspaceRemoteTerminalTransport = .ssh,
        preserveAfterTerminalExit: Bool = true,
        persistentDaemonSlot: String? = "ssh-issue-7989-loss",
        skipDaemonBootstrap: Bool = false
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            transport: transport,
            terminalTransport: terminalTransport,
            destination: "dev@example.com",
            port: 22,
            identityFile: nil,
            sshOptions: ["StrictHostKeyChecking=accept-new"],
            localProxyPort: nil,
            relayPort: relayPort,
            relayID: "relay-issue-7989-loss",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-issue-7989-loss.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(requireExisting: false),
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: persistentDaemonSlot,
            skipDaemonBootstrap: skipDaemonBootstrap
        )
    }

    private func legacyLocalBinding() throws -> SurfaceResumeBindingSnapshot {
        let object: [String: Any] = [
            "name": "Codex",
            "kind": "codex",
            "command": "codex resume legacy-session",
            "cwd": "/tmp/legacy-project",
            "checkpointId": "legacy-session",
            "source": "agent-hook",
            "autoResume": true,
            "updatedAt": 10.0,
        ]
        return try JSONDecoder().decode(
            SurfaceResumeBindingSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func decodedInitialCommand(from bootstrap: String) throws -> String {
        let payloadLine = try #require(bootstrap.split(separator: "\n").first { line in
            line.contains("printf %s '") && line.contains("> \"$cmux_initial_command_tmp\"")
        })
        let prefixRange = try #require(payloadLine.range(of: "printf %s '"))
        let encodedSuffix = payloadLine[prefixRange.upperBound...]
        let closingQuote = try #require(encodedSuffix.firstIndex(of: "'"))
        let encodedCommand = String(encodedSuffix[..<closingQuote])
        let data = try #require(Data(base64Encoded: encodedCommand))
        return try #require(String(data: data, encoding: .utf8))
    }

    private func decodedWrapperRemoteCommand(from startupCommand: String) throws -> String {
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(startupCommand).map(\.value)
        let script = try #require(words.dropFirst(2).first)
        let range = try #require(
            script.range(of: #"--command-b64 [A-Za-z0-9+/=]+"#, options: .regularExpression)
        )
        let encoded = String(script[range]).split(separator: " ", maxSplits: 1).last.map(String.init)
        let data = try #require(encoded.flatMap { Data(base64Encoded: $0) })
        return try #require(String(data: data, encoding: .utf8))
    }
}
