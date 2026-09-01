import CMUXAgentLaunch
import Foundation
import CmuxCore
import Testing
@testable import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SessionPersistenceResumeBindingTests {
    @Test func restoreWorkingDirectorySelectionRoundTripsAndFailsClosed() throws {
        let unsafeDirectory = "/Users/alice/captured-cwd"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok --resume session --cwd '\(unsafeDirectory)'",
            cwd: unsafeDirectory,
            checkpointId: "session",
            source: "agent-hook",
            restoreWorkingDirectorySelection: .unavailable,
            autoResume: true
        )

        let encoded = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(SurfaceResumeBindingSnapshot.self, from: encoded)

        #expect(decoded.restoreWorkingDirectorySelection == .unavailable)
        #expect(decoded.inlineStartupInput(repairPortableAgentExecutable: false) == nil)
        #expect(decoded.remoteStartupInput() == nil)
    }

    @Test func unavailableSelectionErasesPersistedAgentRestoreRecipe() {
        let unsafeDirectory = "/Users/alice/captured-cwd"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok --resume session --cwd '\(unsafeDirectory)'",
            cwd: unsafeDirectory,
            checkpointId: "session",
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "grok",
                executablePath: "/usr/local/bin/grok",
                arguments: ["/usr/local/bin/grok", "--cwd", unsafeDirectory],
                workingDirectory: unsafeDirectory
            ),
            autoResume: true
        )
        let agent = SessionRestorableAgentSnapshot(
            kind: .grok,
            sessionId: "session",
            workingDirectory: unsafeDirectory,
            launchCommand: binding.launchCommand
        )

        let constrained = binding.applyingRestoreWorkingDirectorySelection(
            .unavailable,
            from: agent
        )

        #expect(constrained.restoreWorkingDirectorySelection == .unavailable)
        #expect(constrained.command.isEmpty)
        #expect(constrained.cwd == nil)
        #expect(constrained.launchCommand == nil)
    }

    @Test func exactRestoreWithoutLaunchCapturePreservesBindingEnvironment() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume remote-session",
            cwd: "/home/remote/project",
            checkpointId: "remote-session",
            source: "agent-hook",
            environment: ["CODEX_HOME": "/home/remote/.codex"],
            restoreWorkingDirectorySelection: .exact("/home/remote/project")
        )

        let startupInput = try #require(binding.remoteStartupInput())
        #expect(
            startupInput.contains("CODEX_HOME=/home/remote/.codex"),
            Comment(rawValue: startupInput)
        )
        #expect(startupInput.contains("/home/remote/project"), Comment(rawValue: startupInput))
    }

    @Test func exactRestoreRepairsStaleManagedExecutableBeforeWrapping() throws {
        let staleExecutable = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-shims", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: false)
            .path
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "'\(staleExecutable)' claude-teams --resume stale-session",
            cwd: "/home/remote/project",
            checkpointId: "stale-session",
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claudeTeams",
                executablePath: staleExecutable,
                arguments: [staleExecutable, "claude-teams", "--model", "sonnet"],
                workingDirectory: "/Users/alice/local-project"
            ),
            restoreWorkingDirectorySelection: .exact("/home/remote/project")
        )

        let startupInput = try #require(
            binding.inlineStartupInput(repairPortableAgentExecutable: true)
        )
        #expect(!startupInput.contains(staleExecutable), Comment(rawValue: startupInput))
        #expect(startupInput.contains("claude-teams"), Comment(rawValue: startupInput))
    }

    @Test func localHookRefreshDoesNotInheritRemoteRestorePolicy() throws {
        let sessionID = "same-session-execution-boundary"
        let remoteContext = SurfaceResumeRemoteContext(
            workspaceID: UUID(),
            surfaceID: UUID(),
            persistentPTYSessionID: "remote-pty"
        )
        let remoteBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID)",
            cwd: "/home/remote/project",
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: ["codex", "resume", sessionID],
                workingDirectory: "/home/remote/project"
            ),
            restoreWorkingDirectorySelection: .exact("/home/remote/project"),
            launchFlavor: .persistentSSH(remoteContext)
        )
        let localRefresh = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID)",
            checkpointId: sessionID,
            source: "agent-hook",
            launchFlavor: .local
        )
        let remoteSnapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: "/home/remote/project",
            launchCommand: remoteBinding.launchCommand,
            restoreWorkingDirectorySelection: .exact("/home/remote/project")
        )

        let snapshot = try #require(
            localRefresh.managedRestorableAgentSnapshot(
                replacing: remoteSnapshot,
                previousBinding: remoteBinding
            )
        )
        #expect(snapshot.workingDirectory == nil)
        #expect(snapshot.launchCommand == nil)
        #expect(snapshot.restoreWorkingDirectorySelection == nil)
    }

    @Test func unavailableRestorePolicySurvivesCwdRetargeting() {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume session",
            cwd: nil,
            checkpointId: "session",
            source: "agent-hook",
            restoreWorkingDirectorySelection: .unavailable
        )

        let retargeted = binding.retargetingWorkingDirectory("/remote/new-project")
        #expect(retargeted == binding)
    }

    @Test func persistentSSHOwnerRetargetKeepsSamePTYSessionState() throws {
        let sessionID = "same-session-retarget"
        let persistentPTYSessionID = "stable-remote-pty"
        let sourceContext = SurfaceResumeRemoteContext(
            workspaceID: UUID(),
            surfaceID: UUID(),
            persistentPTYSessionID: persistentPTYSessionID
        )
        let destinationContext = SurfaceResumeRemoteContext(
            workspaceID: UUID(),
            surfaceID: UUID(),
            persistentPTYSessionID: " \(persistentPTYSessionID) "
        )
        let previousBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID)",
            cwd: "/home/remote/project",
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: ["codex", "resume", sessionID],
                workingDirectory: "/home/remote/project"
            ),
            restoreWorkingDirectorySelection: .exact("/home/remote/project"),
            launchFlavor: .persistentSSH(sourceContext)
        )
        let retargetedRefresh = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID)",
            checkpointId: sessionID,
            source: "agent-hook",
            launchFlavor: .persistentSSH(destinationContext)
        )
        let previousSnapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: "/home/remote/project",
            launchCommand: previousBinding.launchCommand,
            restoreWorkingDirectorySelection: .exact("/home/remote/project")
        )

        let snapshot = try #require(
            retargetedRefresh.managedRestorableAgentSnapshot(
                replacing: previousSnapshot,
                previousBinding: previousBinding
            )
        )
        #expect(snapshot.workingDirectory == previousSnapshot.workingDirectory)
        #expect(snapshot.launchCommand == previousSnapshot.launchCommand)
        #expect(
            snapshot.restoreWorkingDirectorySelection ==
                previousSnapshot.restoreWorkingDirectorySelection
        )
    }

    @Test func blankPersistentPTYIDsNeverShareExecutionLocation() {
        let lhs = SurfaceResumeLaunchFlavor.persistentSSH(
            SurfaceResumeRemoteContext(
                workspaceID: UUID(),
                surfaceID: UUID(),
                persistentPTYSessionID: " "
            )
        )
        let rhs = SurfaceResumeLaunchFlavor.persistentSSH(
            SurfaceResumeRemoteContext(
                workspaceID: UUID(),
                surfaceID: UUID(),
                persistentPTYSessionID: "\n"
            )
        )
        #expect(!lhs.representsSameExecutionLocation(as: rhs))
    }

    @MainActor
    @Test func detachedIdKeyedRetargetRefreshesCwdSelection() throws {
        let oldDirectory = "/remote/old-project"
        let liveDirectory = "/remote/live-project"
        let codexBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume detached-session",
            cwd: oldDirectory,
            checkpointId: "detached-session",
            source: "agent-hook",
            restoreWorkingDirectorySelection: .exact(oldDirectory)
        )
        let retargetedCodex = try #require(
            DockSplitStore.dockResumeBinding(
                preservedBinding: codexBinding,
                preservedSessionDirectory: oldDirectory,
                restoredResumeSessionWorkingDirectory: liveDirectory,
                detachedDirectoryWasReadFromLiveForegroundProcess: true,
                agentProvenExited: false
            )
        )

        #expect(retargetedCodex.cwd == liveDirectory)
        #expect(
            retargetedCodex.restoreWorkingDirectorySelection == .exact(liveDirectory)
        )

        let directoryKeyedBinding = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok --resume detached-session",
            cwd: oldDirectory,
            checkpointId: "detached-session",
            source: "agent-hook",
            restoreWorkingDirectorySelection: .exact(oldDirectory)
        )
        let retainedDirectoryKeyed = try #require(
            DockSplitStore.dockResumeBinding(
                preservedBinding: directoryKeyedBinding,
                preservedSessionDirectory: oldDirectory,
                restoredResumeSessionWorkingDirectory: liveDirectory,
                detachedDirectoryWasReadFromLiveForegroundProcess: true,
                agentProvenExited: false
            )
        )
        #expect(retainedDirectoryKeyed.cwd == oldDirectory)
        #expect(
            retainedDirectoryKeyed.restoreWorkingDirectorySelection == .exact(oldDirectory)
        )
    }

    @MainActor
    @Test func localHookRefreshDoesNotApplyRetainedRemotePolicy() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer {
            for workspace in manager.tabs {
                workspace.teardownAllPanels()
            }
        }
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let sessionID = "workspace-execution-boundary"
        let remoteBinding = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok --resume \(sessionID)",
            cwd: "/home/remote/project",
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "grok",
                executablePath: "grok",
                arguments: ["grok", "--resume", sessionID],
                workingDirectory: "/home/remote/project"
            ),
            restoreWorkingDirectorySelection: .exact("/home/remote/project"),
            launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                workspaceID: workspace.id,
                surfaceID: panelID,
                persistentPTYSessionID: "workspace-remote-pty"
            ))
        )
        workspace.surfaceResumeBindingsByPanelId[panelID] = remoteBinding
        workspace.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .grok,
                sessionId: sessionID,
                workingDirectory: "/home/remote/project",
                launchCommand: remoteBinding.launchCommand,
                registration: .builtInGrok,
                restoreWorkingDirectorySelection: .exact("/home/remote/project")
            ),
            panelId: panelID
        )

        let localRefresh = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok --resume \(sessionID)",
            checkpointId: sessionID,
            source: "agent-hook",
            launchFlavor: .local
        )
        #expect(workspace.setSurfaceResumeBinding(localRefresh, panelId: panelID))

        let storedBinding = try #require(workspace.surfaceResumeBinding(panelId: panelID))
        #expect(storedBinding.launchFlavor == .local)
        #expect(storedBinding.restoreWorkingDirectorySelection == nil)
        #expect(storedBinding.cwd == nil)
        #expect(workspace.restoredAgentSnapshotsByPanelId[panelID]?.restoreWorkingDirectorySelection == nil)
        #expect(workspace.restoredAgentSnapshotsByPanelId[panelID]?.workingDirectory == nil)
    }

    @MainActor
    @Test func resumeBindingSelectionChangesAutosaveFingerprint() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer {
            for workspace in manager.tabs {
                workspace.teardownAllPanels()
            }
        }
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        var binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume fingerprint-session",
            cwd: "/srv/project",
            checkpointId: "fingerprint-session",
            source: "agent-hook",
            restoreWorkingDirectorySelection: .exact("/srv/project"),
            autoResume: true
        )
        workspace.surfaceResumeBindingsByPanelId[panelID] = binding
        let exactFingerprint = manager.sessionAutosaveFingerprint()

        binding.restoreWorkingDirectorySelection = .unavailable
        workspace.surfaceResumeBindingsByPanelId[panelID] = binding
        let unavailableFingerprint = manager.sessionAutosaveFingerprint()

        #expect(exactFingerprint != unavailableFingerprint)
    }

    @Test func structuredLaunchCaptureRoundTripsAdditively() throws {
        let binding = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "codex resume legacy-display-command",
            cwd: "/tmp/项目 with 'quotes'",
            checkpointId: "a22293b7-bcef-4707-8439-2f538c8517a4",
            source: "agent-hook",
            environment: ["CODEX_HOME": "/tmp/配置"],
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/opt/company bin/codex",
                arguments: [
                    "/opt/company bin/codex",
                    "--model",
                    "gpt-5.6-sol",
                    "日本語",
                ],
                workingDirectory: "/tmp/项目 with 'quotes'",
                environment: ["CODEX_HOME": "/tmp/配置"],
                capturedAt: 123,
                source: "process"
            ),
            autoResume: true
        )

        let decoded = try JSONDecoder().decode(
            SurfaceResumeBindingSnapshot.self,
            from: JSONEncoder().encode(binding)
        )

        #expect(decoded == binding)
        #expect(decoded.launchCommand?.arguments == binding.launchCommand?.arguments)
        #expect(decoded.command.contains("codex resume legacy-display-command"))
    }

    @Test func v06420CommandOnlyBindingStillProducesRestoreVerb() throws {
        let json = """
        {
          "name": "Legacy custom agent",
          "kind": "custom-agent",
          "command": "legacy-agent --resume 'old checkpoint'",
          "cwd": "/tmp/legacy",
          "checkpointId": "old checkpoint",
          "source": "agent-hook",
          "environment": {"LEGACY_VALUE": "preserved"},
          "autoResume": true,
          "approvalPolicy": "auto",
          "approvalRecordId": "legacy-approval",
          "updatedAt": 1
        }
        """
        let binding = try JSONDecoder().decode(
            SurfaceResumeBindingSnapshot.self,
            from: Data(json.utf8)
        )

        #expect(binding.launchCommand == nil)
        #expect(binding.permissionMode == nil)
        #expect(binding.launchFlavor == .local)
        #expect(binding.wasDecodedWithoutLaunchFlavor)
        #expect(binding.environment == ["LEGACY_VALUE": "preserved"])
        #expect(
            binding.restoreStartupInput()
                == " \(AgentRestoreLaunch.cliStartupExecutableToken) restore --surface\n"
        )
    }

    @Test func localRestoreUsesOneShortCLICommandRegardlessOfBindingSize() throws {
        let sessionId = "a22293b7-bcef-4707-8439-2f538c8517a4"


        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionId) " + String(repeating: "--config model_provider=subrouter ", count: 80),
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.restoreStartupInput())

        #expect(
            startupInput
                == " \(AgentRestoreLaunch.cliStartupExecutableToken) restore codex \(sessionId)\n"
        )
    }

    /// Regression for the first nushell dogfood round: the compatibility
    /// inline startup input stays raw POSIX (local callers apply the nushell
    /// `^/bin/sh -c "…"` envelope only at their typed boundary,
    /// `restoreStartupInput`), and the local restore verb stays bare words,
    /// which parse identically in POSIX shells and nushell.
    @Test func nushellTypingEnvelopeAppliesOnlyAtTheTypedBoundary() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "'claude' '--resume' 'session-nu-envelope'",
            checkpointId: "session-nu-envelope",
            source: "agent-hook",
            autoResume: true
        )

        let raw = try #require(binding.inlineStartupInput)
        #expect(!raw.contains("^/bin/sh"), "inline input must stay raw POSIX: \(raw)")

        let restore = try #require(binding.restoreStartupInput())
        #expect(restore.hasPrefix(" \(AgentRestoreLaunch.cliStartupExecutableToken) restore"), "\(restore)")
        #expect(!restore.contains("^/bin/sh"), "the bare-word restore verb needs no dialect envelope: \(restore)")
        #expect(
            !restore.contains("&&") && !restore.contains("||") && !restore.contains("'"),
            "restore input must stay nushell-parseable bare words: \(restore)"
        )
    }

    @Test(arguments: ["codex", "claude"])
    func agentHookRestoreBindingCarriesProviderAndSessionBoundAuthorization(kind: String) throws {
        let sessionId = "a22293b7-bcef-4707-8439-2f538c8517a4"
        let resumeArgument = kind == "codex" ? "resume" : "--resume"
        let binding = SurfaceResumeBindingSnapshot(
            kind: kind,
            command: "'/opt/company/bin/\(kind)' '\(resumeArgument)' '\(sessionId)'",
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.inlineStartupInput)
        #expect(
            startupInput.contains("/usr/bin/env 'CMUX_AGENT_RESTORE_LAUNCH=\(kind):\(sessionId)'"),
            "\(startupInput)"
        )
        #expect(startupInput.contains("CMUX_\(kind.uppercased())_WRAPPER_SHIM"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_CUSTOM_\(kind.uppercased())_PATH="), "\(startupInput)")
    }

    @Test func restoreBindingAuthorizationRejectsUnownedOrUnboundCommands() throws {
        let sessionId = "a22293b7-bcef-4707-8439-2f538c8517a4"
        let nonHook = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume '\(sessionId)'",
            checkpointId: sessionId,
            source: "cli",
            autoResume: true
        )
        let unsupported = SurfaceResumeBindingSnapshot(
            kind: "gemini",
            command: "gemini --resume '\(sessionId)'",
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true
        )
        let invalidSession = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude --resume not-a-session-id",
            checkpointId: "not-a-session-id",
            source: "agent-hook",
            autoResume: true
        )

        #expect(try #require(nonHook.inlineStartupInput).contains("CMUX_AGENT_RESTORE_LAUNCH") == false)
        #expect(try #require(unsupported.inlineStartupInput).contains("CMUX_AGENT_RESTORE_LAUNCH") == false)
        #expect(try #require(invalidSession.inlineStartupInput).contains("CMUX_AGENT_RESTORE_LAUNCH") == false)
    }

    @Test func agentHookSurfaceResumeRoutesCustomExecutableThroughWrapper() throws {
        let sessionId = "a22293b7-bcef-4707-8439-2f538c8517a4"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "'/opt/company/bin/codex' 'resume' '\(sessionId)'",
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(startupInput.contains("CMUX_CODEX_WRAPPER_SHIM"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_CUSTOM_CODEX_PATH="), "\(startupInput)")
        #expect(startupInput.contains("/opt/company/bin/codex"), "\(startupInput)")
    }

    @Test func decodingAgentHookBindingRewritesPersistedPATHManagedAgentExecutable() throws {
        let executablePath = Self.homeManagedExecutablePath(
            executableName: "claude",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let json = """
        {
          "kind": "claude",
          "command": "{ cd -- '/tmp/project' 2>/dev/null || [ ! -d '/tmp/project' ]; } && '\(executablePath)' '--resume' 'session-moved-cli' '--chrome'",
          "cwd": "/tmp/project",
          "checkpointId": "session-moved-cli",
          "source": "agent-hook",
          "autoResume": true,
          "updatedAt": 123
        }
        """
        let binding = try JSONDecoder().decode(SurfaceResumeBindingSnapshot.self, from: Data(json.utf8))
        let startupInput = try #require(binding.startupInput)

        #expect(binding.command.contains(executablePath), "\(binding.command)")
        #expect(startupInput.contains("/bin/sh -c"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_CLAUDE_WRAPPER_SHIM"), "\(startupInput)")
        #expect(startupInput.contains("--resume"), "\(startupInput)")
        #expect(!startupInput.contains(executablePath), "\(startupInput)")
    }

    @Test func legacyAgentHookBindingWithoutKindRewritesPersistedPATHManagedAgentExecutable() throws {
        let executablePath = Self.homeManagedExecutablePath(
            executableName: "codex",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let json = """
        {
          "command": "'\(executablePath)' 'resume' 'session-legacy-cli'",
          "checkpointId": "session-legacy-cli",
          "source": "agent-hook",
          "autoResume": true,
          "updatedAt": 123
        }
        """
        let binding = try JSONDecoder().decode(SurfaceResumeBindingSnapshot.self, from: Data(json.utf8))
        let startupInput = try #require(binding.startupInput)

        #expect(binding.kind == nil)
        #expect(binding.command.contains(executablePath), "\(binding.command)")
        #expect(startupInput.contains("CMUX_CODEX_WRAPPER_SHIM"), "\(startupInput)")
        #expect(startupInput.contains("resume session-legacy-cli"), "\(startupInput)")
        #expect(!startupInput.contains(executablePath), "\(startupInput)")
    }

    @Test func agentHookBindingRewritesSupportedLocalManagedExecutablePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-stale-managed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executablePaths = [
            Self.localManagedExecutablePath(root: root, executableName: "codex", ".fnm", "current", "bin"),
            "/tmp/cmux-cli-shims/\(UUID().uuidString)/codex",
            Self.localManagedExecutablePath(
                root: root,
                executableName: "codex",
                "Library",
                "Application Support",
                "fnm",
                "node-versions",
                "v24.2.0",
                "installation",
                "bin"
            ),
            Self.localManagedExecutablePath(
                root: root,
                executableName: "codex",
                ".local",
                "share",
                "fnm",
                "node-versions",
                "v24.2.0",
                "installation",
                "bin"
            ),
            Self.localManagedExecutablePath(root: root, executableName: "codex", ".local", "share", "mise", "shims"),
        ]

        for executablePath in executablePaths {
            let binding = SurfaceResumeBindingSnapshot(
                kind: "codex",
                command: "'\(executablePath)' 'resume' 'session-managed-cli'",
                checkpointId: "session-managed-cli",
                source: "agent-hook",
                autoResume: true
            )

            let startupInput = try #require(binding.startupInput)
            #expect(startupInput.contains("CMUX_CODEX_WRAPPER_SHIM"), "\(startupInput)")
            #expect(startupInput.contains("resume session-managed-cli"), "\(startupInput)")
            #expect(!startupInput.contains(executablePath), "\(startupInput)")
        }
    }

    @Test func agentHookBindingWithDirectEnvironmentAssignmentRewritesMovedExecutable() throws {
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "codex",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "CMUX_TRACE=1 '\(staleExecutablePath)' 'resume' 'session-env-cli'",
            checkpointId: "session-env-cli",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(startupInput.contains("CMUX_TRACE=1"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_CODEX_WRAPPER_SHIM"), "\(startupInput)")
        #expect(startupInput.contains("resume session-env-cli"), "\(startupInput)")
        #expect(!startupInput.contains(staleExecutablePath), "\(startupInput)")
    }

    @Test func agentHookBindingWithQuotedEnvAssignmentRewritesMovedExecutable() throws {
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "codex",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "env 'CMUX_TRACE=1' '\(staleExecutablePath)' 'resume' 'session-quoted-env-cli'",
            checkpointId: "session-quoted-env-cli",
            source: "agent-hook",
            autoResume: true
        )
        let startupInput = try #require(binding.startupInput)

        #expect(startupInput.contains("env CMUX_TRACE=1"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_CODEX_WRAPPER_SHIM"), "\(startupInput)")
        #expect(startupInput.contains("resume session-quoted-env-cli"), "\(startupInput)")
        #expect(!startupInput.contains(staleExecutablePath), "\(startupInput)")
    }

    @Test func agentHookClaudeBindingWithDirectEnvironmentAssignmentPreservesAssignmentSyntax() throws {
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "claude",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "CMUX_TRACE='bar baz' '\(staleExecutablePath)' '--resume' 'session-env-cli'",
            checkpointId: "session-env-cli",
            source: "agent-hook",
            autoResume: true
        )
        let startupInput = try #require(binding.startupInput)

        #expect(startupInput.contains("/bin/sh -c"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_CLAUDE_WRAPPER_SHIM"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_TRACE="), "\(startupInput)")
        #expect(startupInput.contains("bar baz"), "\(startupInput)")
        #expect(!startupInput.contains(staleExecutablePath), "\(startupInput)")
    }

    @Test func agentHookClaudeBindingWithShellOperatorKeepsOriginalCommandShape() throws {
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "claude",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let redirection = "1>/tmp/cmux-claude-resume.log"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "'\(staleExecutablePath)' '--resume' 'session-operator-cli' \(redirection) && echo done",
            checkpointId: "session-operator-cli",
            source: "agent-hook",
            autoResume: true
        )
        let startupInput = try #require(binding.startupInput)

        #expect(binding.command.contains("&& echo done"), "\(binding.command)")
        #expect(binding.command.contains(staleExecutablePath), "\(binding.command)")
        #expect(startupInput.contains("/bin/sh -c"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_CLAUDE_WRAPPER_SHIM"), "\(startupInput)")
        #expect(startupInput.contains("session-operator-cli \(redirection) && echo done"), "\(startupInput)")
        #expect(!startupInput.contains(staleExecutablePath), "\(startupInput)")
    }

    @Test func agentHookBindingPreservesRemoteManagedExecutablePath() throws {
        let remoteExecutablePath = "/home/me/.nvm/versions/node/v24.2.0/bin/codex"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "'\(remoteExecutablePath)' 'resume' 'session-remote-cli'",
            checkpointId: "session-remote-cli",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)
        #expect(startupInput.contains("'\(remoteExecutablePath)' 'resume' 'session-remote-cli'"), "\(startupInput)")
    }

    @Test func remoteStartupInputPreservesLocalLookingManagedExecutablePaths() throws {
        let executablePaths = [
            Self.homeManagedExecutablePath(
                executableName: "codex",
                ".nvm",
                "versions",
                "node",
                "cmux-missing-\(UUID().uuidString)",
                "bin"
            ),
            "/tmp/cmux-cli-shims/\(UUID().uuidString)/codex",
        ]

        for executablePath in executablePaths {
            let binding = SurfaceResumeBindingSnapshot(
                kind: "codex",
                command: "'\(executablePath)' 'resume' 'session-remote-local-looking-cli'",
                checkpointId: "session-remote-local-looking-cli",
                source: "agent-hook",
                autoResume: true
            )

            let startupInput = try #require(binding.inlineStartupInput(
                repairPortableAgentExecutable: false
            ))
            #expect(
                startupInput.contains("'\(executablePath)' 'resume' 'session-remote-local-looking-cli'"),
                "\(startupInput)"
            )
        }
    }

    @Test @MainActor func remoteWorkspaceLocalTerminalResumeBindingUsesShortLocalRestoreVerb() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-local-resume-binding-\(UUID().uuidString)", isDirectory: true)
        let localDirectoryURL = root.appendingPathComponent("local repo", isDirectory: true)
        try fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let suiteName = "cmux-session-resume-binding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let remoteWorkspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        remoteWorkspace.setCustomTitle("Remote Workspace With Local Resume Binding")
        remoteWorkspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "dev@example.com",
                port: 2222,
                identityFile: nil,
                sshOptions: [
                    "StrictHostKeyChecking=accept-new",
                ],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: "ssh -p 2222 dev@example.com",
                preserveAfterTerminalExit: false
            ),
            autoConnect: false
        )
        let paneId = try #require(remoteWorkspace.bonsplitController.allPaneIds.first)
        let localDirectory = localDirectoryURL.path
        let localPanel = try #require(remoteWorkspace.newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: localDirectory,
            suppressWorkspaceRemoteStartupCommand: true
        ))
        remoteWorkspace.setPanelCustomTitle(panelId: localPanel.id, title: "Local Resume Shell")
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "codex",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let oversizedArgument = String(
            repeating: "x",
            count: 901
        )
        let quotedDirectory = "'\(localDirectory)'"
        #expect(remoteWorkspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "{ cd -- \(quotedDirectory) 2>/dev/null || [ ! -d \(quotedDirectory) ]; } && "
                    + "'\(staleExecutablePath)' 'resume' 'session-local-resume' '\(oversizedArgument)'",
                cwd: localDirectory,
                checkpointId: "session-local-resume",
                source: "agent-hook",
                autoResume: true,
                updatedAt: 10
            ),
            panelId: localPanel.id
        ))

        let snapshot = remoteWorkspace.sessionSnapshot(includeScrollback: false)
        let persistedLocalPanel = try #require(snapshot.panels.first {
            $0.customTitle == "Local Resume Shell"
        })
        #expect(persistedLocalPanel.terminal?.isRemoteTerminal == false)
        #expect(persistedLocalPanel.terminal?.resumeBinding?.command.contains(staleExecutablePath) == true)

        let restoredWorkspace = Workspace(
            agentSessionAutoResumeDefaults: defaults,
            restorableAgentIndexProvider: { .empty }
        )
        restoredWorkspace.restoreSessionSnapshot(snapshot)
        let restoredLocalPanel = try #require(
            restoredWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.customTitle == "Local Resume Shell" }
        )
        let restoredPanel = try #require(restoredWorkspace.terminalPanel(for: restoredLocalPanel.id))
        #expect(restoredPanel.surface.debugInitialCommand() == nil)
        let restoredInput = try #require(
            restoredPanel.surface.debugInitialInputForTesting()
                ?? restoredPanel.surface.nextRuntimeInitialInput
        )
        #expect(restoredPanel.requestedWorkingDirectory == localDirectory)
        #expect(
            restoredInput
                == " \(AgentRestoreLaunch.cliStartupExecutableToken) restore codex session-local-resume\n"
        )
        #expect(!restoredInput.contains(staleExecutablePath))
        #expect(!restoredInput.contains(oversizedArgument))
    }

    @Test func agentHookSurfaceResumeStartupInputPreservesExistingPATHManagedAgentExecutable() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-existing-agent-\(UUID().uuidString)", isDirectory: true)
        let executable = root
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
            .appendingPathComponent("v24.2.0", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
        try fileManager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? fileManager.removeItem(at: root) }

        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "'\(executable.path)' 'resume' 'session-existing-cli'",
            checkpointId: "session-existing-cli",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)
        #expect(startupInput.contains("'\(executable.path)'"), "\(startupInput)")
    }

    @Test func agentHookSurfaceResumeStartupInputFallsBackWhenRecordedAgentExecutableMoved() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-moved-agent-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let movedExecutable = root
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
            .appendingPathComponent("v24.2.0", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
        let outputURL = root.appendingPathComponent("codex-output.txt", isDirectory: false)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fakeCodex = bin.appendingPathComponent("codex", isDirectory: false)
        try """
        #!/bin/sh
        printf '%s|%s\\n' "$PWD" "$*" > "$CMUX_FAKE_CODEX_OUTPUT"
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodex.path)

        let quotedCwd = "'\(cwd.path)'"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "{ cd -- \(quotedCwd) 2>/dev/null || [ ! -d \(quotedCwd) ]; } && "
                + "'\(movedExecutable.path)' 'resume' 'session-moved-cli' '--yolo'",
            cwd: cwd.path,
            checkpointId: "session-moved-cli",
            source: "agent-hook",
            autoResume: true
        )
        let startupInput = try #require(binding.startupInput)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-fc", startupInput]
        process.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin",
            "CMUX_FAKE_CODEX_OUTPUT": outputURL.path,
        ]
        let stderr = Pipe()
        process.standardError = stderr

        try runWithBoundedWait(process, shellDescription: "zsh -fc")

        let errorText = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0, "\(errorText)")

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(output == "\(cwd.path)|resume session-moved-cli -c check_for_update_on_startup=false --yolo\n")
        #expect(!startupInput.contains(movedExecutable.path), "\(startupInput)")
    }

    private struct ResumeShellTimeout: Error, CustomStringConvertible {
        let shellDescription: String
        let timeout: TimeInterval

        var description: String {
            "Resume shell (\(shellDescription)) did not exit within \(Int(timeout))s; treating as hung."
        }
    }

    private func runWithBoundedWait(
        _ process: Process,
        shellDescription: String,
        timeout: TimeInterval = 30
    ) throws {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            throw ResumeShellTimeout(shellDescription: shellDescription, timeout: timeout)
        }
    }

    private static func homeManagedExecutablePath(executableName: String, _ components: String...) -> String {
        localManagedExecutablePath(root: FileManager.default.homeDirectoryForCurrentUser, executableName: executableName, components)
    }

    private static func localManagedExecutablePath(
        root: URL,
        executableName: String,
        _ components: String...
    ) -> String {
        localManagedExecutablePath(root: root, executableName: executableName, components)
    }

    private static func localManagedExecutablePath(
        root: URL,
        executableName: String,
        _ components: [String]
    ) -> String {
        var directory = root
        for component in components {
            directory.appendPathComponent(component, isDirectory: true)
        }
        return directory.appendingPathComponent(executableName, isDirectory: false).path
    }
}
