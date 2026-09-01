import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CMUXCLIForkVerbRegressionTests {
    private final class BundleToken {}
    @Test
    func snapshotForkVerbUsesNativeAndRegistrationForkArgv() throws {
        let sessionID = "fork-session"
        let nativeCases: [(RestorableAgentKind, String, [String])] = [
            (.claude, "claude", ["claude", "--resume", sessionID, "--fork-session"]),
            (.codex, "codex", ["codex", "fork", sessionID]),
            (.opencode, "opencode", ["opencode", "--session", sessionID, "--fork"]),
            (.pi, "pi", ["pi", "--fork", sessionID]),
            (.omp, "omp", ["omp", "--fork", sessionID]),
        ]
        for (kind, executable, expectedArguments) in nativeCases {
            let snapshot = SessionRestorableAgentSnapshot(
                kind: kind,
                sessionId: sessionID,
                workingDirectory: nil,
                launchCommand: AgentLaunchCommandSnapshot(arguments: [executable])
            )
            #expect(snapshot.preparedForkArguments() == expectedArguments)
            #expect(snapshot.forkStartupInput(useLocalForkVerb: true) == " cmux fork \(kind.rawValue) \(sessionID)\n")
        }

        let registration = CmuxVaultAgentRegistration(
            id: "forkable-agent",
            name: "Forkable Agent",
            detect: CmuxVaultAgentDetectRule(processNames: ["forkable-agent"]),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}}",
            forkCommand: "{{executable}} --branch {{sessionId}}"
        )
        let custom = SessionRestorableAgentSnapshot(
            kind: .custom(registration.id),
            sessionId: sessionID,
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(arguments: ["forkable-agent"]),
            registration: registration
        )
        #expect(custom.preparedForkArguments() == ["forkable-agent", "--branch", sessionID])
        #expect(custom.forkStartupInput(useLocalForkVerb: true) == " cmux fork forkable-agent \(sessionID)\n")
    }

    @Test
    func registrationForkTemplatesCoverAgentKinds() {
        let sessionID = "fork-template-session"
        let cases: [(RestorableAgentKind, String)] = [
            (.codex, "codex-template"),
            (.opencode, "opencode-template"),
            (.pi, "pi-template"),
            (.omp, "omp-template"),
            (.hermesAgent, "hermes-template"),
            (.custom("custom-template"), "custom-template"),
        ]
        for (kind, registrationID) in cases {
            let executable = "agent-\(registrationID)"
            let registration = CmuxVaultAgentRegistration(
                id: registrationID,
                name: registrationID,
                detect: CmuxVaultAgentDetectRule(processNames: [executable]),
                sessionIdSource: .argvOption("--session"),
                resumeCommand: "{{executable}} --resume {{sessionId}}",
                forkCommand: "{{executable}} --branch {{sessionId}}"
            )
            let snapshot = SessionRestorableAgentSnapshot(
                kind: kind,
                sessionId: sessionID,
                workingDirectory: nil,
                launchCommand: AgentLaunchCommandSnapshot(arguments: [executable]),
                registration: registration
            )
            #expect(snapshot.preparedForkArguments() == [executable, "--branch", sessionID])
        }
    }

    @Test
    func ignoredRegistrationDoesNotRetargetForkWorkingDirectory() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "ignore-cwd-agent",
            name: "Ignore CWD Agent",
            detect: CmuxVaultAgentDetectRule(processNames: ["ignore-cwd-agent"]),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --resume {{sessionId}}",
            forkCommand: "{{executable}} --fork {{sessionId}}",
            cwd: .ignore
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom(registration.id),
            sessionId: "ignore-cwd-session",
            workingDirectory: "/tmp/original",
            launchCommand: AgentLaunchCommandSnapshot(
                arguments: ["ignore-cwd-agent"],
                workingDirectory: "/tmp/original"
            ),
            registration: registration
        )

        let retargeted = snapshot.retargetingForkWorkingDirectory("/tmp/destination")
        #expect(retargeted.workingDirectory == nil)
        #expect(retargeted.launchCommand?.workingDirectory == nil)
        #expect(retargeted.preparedForkArguments() == ["ignore-cwd-agent", "--fork", "ignore-cwd-session"])
    }

    @Test
    func surfaceResumeCanonicalizerUsesForkSelectorForLocalBindings() throws {
        let sessionID = "019dad34-d218-7943-b81a-eddac5c87951"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude --resume \(sessionID)",
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true
        )
        #expect(binding.usesLocalForkVerb)
        #expect(binding.forkStartupInput() == " cmux fork claude \(sessionID)\n")
    }

    @Test
    func directBindingsDoNotAdvertisePreparedForkArguments() throws {
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        defer { tabManager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(tabManager.addWorkspaceIfActive(autoWelcomeIfNeeded: false))
        let panelID = try #require(workspace.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "claude --resume direct-session",
            checkpointId: "direct-session",
            source: "manual",
            autoResume: false
        )
        workspace.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: "stale-session",
                workingDirectory: nil,
                launchCommand: AgentLaunchCommandSnapshot(arguments: ["claude"])
            ),
            panelId: panelID
        )
        workspace.surfaceResumeBindingsByPanelId[panelID] = binding
        let target = ControlSurfaceResumeTarget.workspace(
            tabManager: tabManager,
            workspace: workspace,
            surfaceID: panelID
        )

        let record = try #require(
            TerminalController.shared.controlSurfaceRestoreRecord(
                target: target,
                binding: binding
            )
        )
        #expect(record.forkArguments == nil)
    }

    @Test
    func agentHookRelaunchKindsKeepRelaunchMode() throws {
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        defer { tabManager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(tabManager.addWorkspaceIfActive(autoWelcomeIfNeeded: false))
        let panelID = try #require(workspace.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            kind: "ollama",
            command: "ollama run llama3",
            checkpointId: nil,
            source: "agent-hook",
            autoResume: true
        )
        workspace.surfaceResumeBindingsByPanelId[panelID] = binding
        let target = ControlSurfaceResumeTarget.workspace(
            tabManager: tabManager,
            workspace: workspace,
            surfaceID: panelID
        )

        let record = try #require(
            TerminalController.shared.controlSurfaceRestoreRecord(
                target: target,
                binding: binding
            )
        )
        #expect(record.modeRawValue == AgentRestoreRequestMode.relaunchAgent.rawValue)
    }

    @Test
    func surfaceRestoreRecordCarriesStructuredForkArguments() throws {
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        defer { tabManager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(
            tabManager.addWorkspaceIfActive(autoWelcomeIfNeeded: false)
        )
        let panelID = try #require(workspace.focusedPanelId)
        let registration = CmuxVaultAgentRegistration(
            id: "record-fork-agent",
            name: "Record Fork Agent",
            detect: CmuxVaultAgentDetectRule(processNames: ["record-fork-agent"]),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}}",
            forkCommand: "{{executable}} --fork {{sessionId}}"
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom(registration.id),
            sessionId: "record-session",
            workingDirectory: "/tmp/record-fork",
            launchCommand: AgentLaunchCommandSnapshot(
                arguments: ["record-fork-agent"],
                workingDirectory: "/tmp/record-fork"
            ),
            registration: registration
        )
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: panelID)
        let target = ControlSurfaceResumeTarget.workspace(
            tabManager: tabManager,
            workspace: workspace,
            surfaceID: panelID
        )

        let record = try #require(
            TerminalController.shared.controlSurfaceRestoreRecord(
                target: target,
                binding: nil
            )
        )
        #expect(record.forkArguments == ["record-fork-agent", "--fork", "record-session"])
        #expect(record.legacyForkCommand?.contains("--fork") == true)
    }

    @Test
    func forkAndRestoreRejectTheSameSelectorShapes() throws {
        let malformedForms = [
            ["--surface", "surface:4", "claude"],
            ["--surface=surface:4", "--surface", "surface:5", "claude", "checkpoint"],
        ]
        let home = try isolatedCLIHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for form in malformedForms {
            let socketPath = "/tmp/cmux-continuation-selector-\(UUID().uuidString.prefix(8)).sock"
            let responder = try UnixSocketResponder(path: socketPath, response: "{\"ok\":true,\"result\":{}}")
            defer { responder.stop() }
            var environment = isolatedCLIEnvironment(socketPath: socketPath, home: home)
            let restore = try runCLI(arguments: ["restore"] + form, environment: environment)
            let fork = try runCLI(arguments: ["fork"] + form, environment: environment)
            #expect(restore.status != 0)
            #expect(fork.status != 0)
            #expect(restore.stderr.contains("Usage: cmux restore"))
            #expect(fork.stderr.contains("Usage: cmux fork"))
        }
    }

    @Test
    func contextMenuForkQueuesForkVerbAndStagesParentRecord() async throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let sourcePanelID = try #require(workspace.focusedPanelId)
        let sessionID = "019dad34-d218-7943-b81a-eddac5c87951"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionID,
            workingDirectory: "/tmp/fork verb repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude"],
                workingDirectory: "/tmp/fork verb repo",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelID)
        #expect(await workspace.forkAgentConversationFromContextMenu(
            fromPanelId: sourcePanelID,
            destination: .newTab
        ))

        let forkPanelID = try #require(workspace.focusedPanelId)
        let forkPanel = try #require(workspace.terminalPanel(for: forkPanelID))
        #expect(forkPanel.surface.initialInput == " cmux fork claude \(sessionID)\n")
        #expect(workspace.restoredAgentSnapshotsByPanelId[forkPanelID] == snapshot)
    }

    @Test
    func cliForkVerbExecutesStructuredForkArguments() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-fork-verb-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("fork-agent", isDirectory: false)
        let marker = root.appendingPathComponent("fork-agent-output", isDirectory: false)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try """
        #!/bin/sh
        {
          printf 'pwd=%s\\n' "$PWD"
          printf 'value=%s\\n' "$CODEX_HOME"
          for argument in "$@"; do printf 'arg=%s\\n' "$argument"; done
        } > "$FORK_TEST_MARKER"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let surfaceID = UUID().uuidString.lowercased()
        let checkpointID = "fork-checkpoint"
        let responseData = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "result": [
                "restore_record": [
                    "mode": "resumeAgent",
                    "kind": "custom-agent",
                    "checkpoint_id": checkpointID,
                    "source": "session-snapshot",
                    "working_directory": root.path,
                    "environment": ["CODEX_HOME": "structured value"],
                    "launch_command": [
                        "arguments": [executable.path],
                        "executable_path": executable.path,
                        "working_directory": root.path,
                        "environment": ["CODEX_HOME": "structured value"],
                    ],
                    "fork_arguments": [executable.path, "--fork", checkpointID],
                ],
            ],
        ])
        let socketPath = "/tmp/cmux-fork-verb-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: String(decoding: responseData, as: UTF8.self)
        )
        defer { responder.stop() }

        let home = try isolatedCLIHome()
        defer { try? fileManager.removeItem(at: home) }
        var environment = isolatedCLIEnvironment(socketPath: socketPath, home: home)
        environment["FORK_TEST_MARKER"] = marker.path
        environment["PATH"] = "/usr/bin:/bin"

        let result = try runCLI(
            arguments: ["fork", "--surface", surfaceID, "custom-agent", checkpointID],
            environment: environment
        )
        #expect(result.status == 0, result.description)
        let output = try String(contentsOf: marker, encoding: .utf8)
        #expect(output.contains("pwd=\(root.path)"))
        #expect(output.contains("value=structured value"))
        #expect(output.contains("arg=--fork"))
        #expect(output.contains("arg=\(checkpointID)"))
        #expect(responder.receivedRequests.last?.contains("surface.resume.get") == true)
    }

    @Test
    func cliForkVerbReportsMissingForkSupport() throws {
        let fileManager = FileManager.default
        let surfaceID = UUID().uuidString.lowercased()
        let checkpointID = "unsupported-fork-checkpoint"
        let responseData = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "result": [
                "restore_record": [
                    "mode": "resumeAgent",
                    "kind": "custom-agent",
                    "checkpoint_id": checkpointID,
                    "source": "session-snapshot",
                    "launch_command": [
                        "arguments": ["custom-agent", "--resume", checkpointID],
                    ],
                ],
            ],
        ])
        let socketPath = "/tmp/cmux-fork-unsupported-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: String(decoding: responseData, as: UTF8.self)
        )
        defer { responder.stop() }

        let home = try isolatedCLIHome()
        defer { try? fileManager.removeItem(at: home) }
        var environment = isolatedCLIEnvironment(socketPath: socketPath, home: home)
        environment["PATH"] = "/usr/bin:/bin"

        let result = try runCLI(
            arguments: ["fork", "--surface", surfaceID, "custom-agent", checkpointID],
            environment: environment
        )
        #expect(result.status != 0, result.description)
        #expect(result.stderr.contains("does not support forking"), result.description)
    }

    private struct ProcessResult: CustomStringConvertible {
        let status: Int32
        let stdout: String
        let stderr: String

        var description: String {
            "status=\(status) stdout=\(stdout) stderr=\(stderr)"
        }
    }

    private func runCLI(
        arguments: [String],
        environment: [String: String]
    ) throws -> ProcessResult {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func isolatedCLIHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fork-cli-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func isolatedCLIEnvironment(
        socketPath: String,
        home: URL
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("CMUX_") && !$0.key.hasPrefix("CMUXD_")
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["AppleLanguages"] = "(en)"
        environment["AppleLocale"] = "en_US_POSIX"
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "C"
        return environment
    }
}
