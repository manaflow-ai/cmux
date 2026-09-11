import AppKit
import CMUXAgentLaunch
import CmuxControlSocket
import CmuxCore
import CmuxSidebar
import Darwin
import Foundation
import Testing
@testable import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif
@Suite(.serialized)
struct RemoteAgentRestoreWorkingDirectoryTests {
    @Test func retainedExactSelectionSurvivesPersistenceAndEveryCommandEntrypoint() throws {
        let capturedAgentDirectory = "/Users/alice/captured-agent-cwd"
        let capturedLaunchDirectory = "/Users/alice/captured-launch-cwd"
        let capturedArgumentDirectory = "/Users/alice/captured-argument-cwd"
        let overrideDirectory = "/Users/alice/binding-override-cwd"
        let trustedRemoteDirectory = "/home/remote/project"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "retained-exact-codex",
            workingDirectory: capturedAgentDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: [
                    "/usr/local/bin/codex",
                    "-C\(capturedArgumentDirectory)",
                    "--model",
                    "test-model",
                ],
                workingDirectory: capturedLaunchDirectory
            )
        )
        let constrained = snapshot.applyingRestoreWorkingDirectorySelection(
            .exact(trustedRemoteDirectory)
        )

        #expect(constrained.workingDirectory == trustedRemoteDirectory)
        #expect(constrained.launchCommand?.workingDirectory == nil)
        #expect(constrained.launchCommand?.arguments.contains { argument in
            argument.contains(capturedArgumentDirectory)
        } == false)

        let encoded = try JSONEncoder().encode(constrained)
        let decoded = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: encoded
        )
        #expect(decoded.restoreWorkingDirectorySelection == .exact(trustedRemoteDirectory))

        let resumeCommand = try #require(decoded.resumeCommand)
        let forkCommand = try #require(decoded.forkCommand)
        let explicitFallbackResume = try #require(decoded.resumeCommand(
            includeWorkingDirectoryPrefix: true,
            workingDirectorySelection: .recordedFallback(preferred: capturedAgentDirectory)
        ))
        let startupInput = try #require(decoded.resumeStartupInput(useLocalRestoreVerb: false))
        for command in [resumeCommand, forkCommand, explicitFallbackResume, startupInput] {
            #expect(command.contains(trustedRemoteDirectory), Comment(rawValue: command))
            #expect(!command.contains(capturedAgentDirectory), Comment(rawValue: command))
            #expect(!command.contains(capturedLaunchDirectory), Comment(rawValue: command))
            #expect(!command.contains(capturedArgumentDirectory), Comment(rawValue: command))
        }

        let override = AgentLaunchCommandSnapshot(
            launcher: "codex",
            executablePath: "/usr/local/bin/codex",
            arguments: ["/usr/local/bin/codex", "-C", overrideDirectory, "--model", "override"],
            workingDirectory: overrideDirectory
        )
        let preparedArguments = try #require(decoded.preparedResumeArguments(
            launchCommand: override,
            workingDirectorySelection: .recordedFallback(preferred: overrideDirectory),
            observedPermissionMode: nil
        ))
        #expect(!preparedArguments.contains("-C"))
        #expect(!preparedArguments.contains { $0.contains(overrideDirectory) })
    }

    @Test func retainedUnavailableSelectionDisablesEveryCommandEntrypoint() throws {
        let capturedDirectory = "/Users/alice/captured-cwd"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .grok,
            sessionId: "retained-unavailable-grok",
            workingDirectory: capturedDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "grok",
                executablePath: "grok",
                arguments: ["grok", "--cwd", capturedDirectory],
                workingDirectory: capturedDirectory
            ),
            registration: .builtInGrok
        )
        let unavailable = snapshot.applyingRestoreWorkingDirectorySelection(.unavailable)

        #expect(unavailable.workingDirectory == nil)
        #expect(unavailable.launchCommand?.workingDirectory == nil)
        #expect(unavailable.launchCommand?.arguments.contains(capturedDirectory) == false)
        #expect(unavailable.resumeCommand == nil)
        #expect(unavailable.forkCommand == nil)
        #expect(unavailable.resumeStartupInput(useLocalRestoreVerb: false) == nil)
        #expect(unavailable.preparedResumeArguments(
            launchCommand: snapshot.launchCommand,
            workingDirectory: capturedDirectory,
            observedPermissionMode: nil
        ) == nil)

        let encoded = try JSONEncoder().encode(unavailable)
        let decoded = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: encoded
        )
        #expect(decoded.restoreWorkingDirectorySelection == .unavailable)
        #expect(decoded.resumeCommand == nil)
        #expect(decoded.forkCommand == nil)
        #expect(
            TabManager.restorableAgentSnapshotFingerprint(snapshot) !=
                TabManager.restorableAgentSnapshotFingerprint(decoded)
        )
    }

    @Test func remoteResumeWithoutPersistedSelectionRejectsCapturedCwd() {
        let capturedDirectory = "/Users/alice/captured-cwd"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "unscoped-remote-resume",
            workingDirectory: capturedDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: ["codex", "--cwd", capturedDirectory],
                workingDirectory: capturedDirectory
            )
        )

        #expect(snapshot.remoteResumeStartupInput() == nil)
    }

    @Test func bindingExactSelectionRemainsAuthoritativeOverStaleAgentSelection() throws {
        let capturedDirectory = "/Users/alice/captured-binding-cwd"
        let sessionID = "binding-authority-session"
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "codex",
            executablePath: "/usr/local/bin/codex",
            arguments: ["/usr/local/bin/codex", "-C", capturedDirectory, "resume", sessionID],
            workingDirectory: capturedDirectory
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume " + sessionID,
            cwd: capturedDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: launchCommand,
            restoreWorkingDirectorySelection: .exact(nil),
            autoResume: true
        )
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: capturedDirectory,
            launchCommand: launchCommand,
            restoreWorkingDirectorySelection: .exact(capturedDirectory)
        )

        let constrained = binding.applyingRestoreWorkingDirectorySelection(
            .exact(capturedDirectory),
            from: agent
        )

        #expect(constrained.restoreWorkingDirectorySelection == .exact(nil))
        #expect(constrained.cwd == nil)
        #expect(!constrained.command.contains(capturedDirectory))
        #expect(constrained.launchCommand?.workingDirectory == nil)
        #expect(constrained.launchCommand?.arguments.contains(capturedDirectory) == false)
    }

    @Test func legacySnapshotWithoutSelectionKeepsRecordedFallbackBehavior() throws {
        let recordedDirectory = "/tmp/legacy-recorded-cwd"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "legacy-recorded-codex",
            workingDirectory: recordedDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: ["codex"]
            )
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: encoded
        )
        #expect(decoded.restoreWorkingDirectorySelection == nil)
        let command = try #require(decoded.resumeCommand)
        #expect(command.contains(recordedDirectory), Comment(rawValue: command))
    }

    @Test func exactSelectionStripsRegisteredBuiltInRecordedCwdArguments() throws {
        let recordedLocalDirectory = "/Users/alice/recorded-agent-cwd"
        let trustedRemoteDirectory = "/repo-b"
        let cases: [(
            kind: RestorableAgentKind,
            registration: CmuxVaultAgentRegistration,
            executable: String,
            cwdOption: String,
            cwdArgument: String,
            launchWorkingDirectory: String?
        )] = [
            (
                .grok,
                .builtInGrok,
                "grok",
                "--cwd",
                "/Users/alice/grok-explicit-cwd",
                "/tmp/grok-process-cwd"
            ),
            (
                .kimi,
                .builtInKimi,
                "kimi",
                "--work-dir",
                "/Users/alice/kimi-explicit-cwd",
                nil
            ),
        ]

        for testCase in cases {
            let sessionId = "remote-\(testCase.executable)-session"
            let snapshot = SessionRestorableAgentSnapshot(
                kind: testCase.kind,
                sessionId: sessionId,
                workingDirectory: recordedLocalDirectory,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: testCase.executable,
                    executablePath: testCase.executable,
                    arguments: [testCase.executable, testCase.cwdOption, testCase.cwdArgument],
                    workingDirectory: testCase.launchWorkingDirectory,
                    environment: [:],
                    capturedAt: 1_777_777_777,
                    source: "process"
                ),
                registration: testCase.registration
            )

            for exactDirectory in [trustedRemoteDirectory, nil] as [String?] {
                let input = try #require(
                    snapshot
                        .applyingRestoreWorkingDirectorySelection(.exact(exactDirectory))
                        .resumeStartupInput(useLocalRestoreVerb: false)
                )
                #expect(input.contains(sessionId), Comment(rawValue: input))
                #expect(!input.contains(recordedLocalDirectory), Comment(rawValue: input))
                #expect(!input.contains(testCase.cwdArgument), Comment(rawValue: input))
                #expect(!input.contains(testCase.cwdOption), Comment(rawValue: input))
                if let exactDirectory {
                    #expect(input.contains(exactDirectory), Comment(rawValue: input))
                }
            }
        }
    }

    @Test func exactSelectionStripsAttachedShortCwdArguments() throws {
        let trustedRemoteDirectory = "/repo-b"
        let cases: [(
            kind: RestorableAgentKind,
            registration: CmuxVaultAgentRegistration?,
            executable: String,
            attachedCwdOption: String
        )] = [
            (.codex, nil, "codex", "-C/Users/alice/codex-explicit-cwd"),
            (.qoder, nil, "qodercli", "-w/Users/alice/qoder-explicit-cwd"),
            (.kimi, .builtInKimi, "kimi", "-w/Users/alice/kimi-explicit-cwd"),
        ]

        for testCase in cases {
            let sessionId = "remote-\(testCase.executable)-attached-cwd"
            let snapshot = SessionRestorableAgentSnapshot(
                kind: testCase.kind,
                sessionId: sessionId,
                workingDirectory: "/Users/alice/recorded-agent-cwd",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: testCase.executable,
                    executablePath: testCase.executable,
                    arguments: [testCase.executable, testCase.attachedCwdOption],
                    workingDirectory: "/tmp/process-cwd",
                    environment: [:],
                    capturedAt: 1_777_777_777,
                    source: "process"
                ),
                registration: testCase.registration
            )

            for exactDirectory in [trustedRemoteDirectory, nil] as [String?] {
                let input = try #require(
                    snapshot
                        .applyingRestoreWorkingDirectorySelection(.exact(exactDirectory))
                        .resumeStartupInput(useLocalRestoreVerb: false)
                )
                #expect(input.contains(sessionId), Comment(rawValue: input))
                #expect(!input.contains(testCase.attachedCwdOption), Comment(rawValue: input))
                if let exactDirectory {
                    #expect(input.contains(exactDirectory), Comment(rawValue: input))
                }
            }
        }
    }

    @Test func exactSelectionPreservesClaudeTeamsWorktreeArguments() throws {
        let worktree = "/tmp/team-worktree"
        let worktreeArguments = [
            ["-w", worktree],
            ["-w\(worktree)"],
        ]

        for arguments in worktreeArguments {
            let snapshot = SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: "remote-claude-team",
                workingDirectory: "/Users/alice/recorded-agent-cwd",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "claudeTeams",
                    executablePath: "cmux",
                    arguments: ["cmux", "claude-teams"] + arguments,
                    workingDirectory: "/Users/alice/recorded-launch-cwd",
                    environment: [:],
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            )

            let input = try #require(
                snapshot
                    .applyingRestoreWorkingDirectorySelection(.exact(nil))
                    .resumeStartupInput(useLocalRestoreVerb: false)
            )
            #expect(input.contains(worktree), Comment(rawValue: input))
            #expect(input.contains("'-w"), Comment(rawValue: input))
        }
    }

    @MainActor
    @Test func genericDirectoryReportCannotSeedEmptyTrustRequiredRemotePanel() throws {
        let localDirectory = "/Users/alice/development"
        let genericDirectory = "/repo-a"
        let remoteCommand = "ssh cmux-remote"
        let workspace = Workspace(
            workingDirectory: localDirectory,
            initialTerminalCommand: remoteCommand
        )
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(
            remoteWorkspaceConfiguration(command: remoteCommand),
            autoConnect: false
        )
        workspace.panelDirectories.removeValue(forKey: panelId)

        #expect(workspace.remoteDirectoryTrustRequiredPanelIds.contains(panelId))
        #expect(!workspace.updatePanelDirectory(panelId: panelId, directory: genericDirectory))
        #expect(workspace.panelDirectories[panelId] == nil)
        #expect(workspace.reportedPanelDirectory(panelId: panelId) == nil)
    }

}
