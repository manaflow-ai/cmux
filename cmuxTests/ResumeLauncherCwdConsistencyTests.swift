import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite("Resume launcher cwd consistency")
struct ResumeLauncherCwdConsistencyTests {
    @Test("local restore keeps cwd-sensitive argv structured behind the short verb")
    func localRestoreUsesShortVerbForCwdSensitiveAgent() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-9200-retarget-\(UUID().uuidString)", isDirectory: true)
        let savedDirectory = root.appendingPathComponent("saved", isDirectory: true)
        let restoredDirectory = root.appendingPathComponent("restored", isDirectory: true)
        try fileManager.createDirectory(at: restoredDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let registration = CmuxVaultAgentRegistration(
            id: "cwd-agent",
            name: "CWD Agent",
            detect: CmuxVaultAgentDetectRule(processName: "cwd-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --cwd {{cwd}} --session {{sessionId}}",
            cwd: .preserve
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("cwd-agent"),
            sessionId: "session-9200",
            workingDirectory: savedDirectory.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "cwd-agent",
                executablePath: "cwd-agent",
                arguments: ["cwd-agent"],
                workingDirectory: savedDirectory.path,
                environment: nil,
                capturedAt: 123,
                source: "test"
            ),
            registration: registration
        )

        let input = try #require(snapshot.resumeStartupInput(
            restoringWorkingDirectory: restoredDirectory.path
        ))
        #expect(
            input
                == " \(AgentRestoreLaunch.cliStartupExecutableToken) restore cwd-agent session-9200\n"
        )
        #expect(
            try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent) == ["restored"]
        )

        let preparedArguments = try #require(
            snapshot.preparedResumeArguments(
                launchCommand: snapshot.launchCommand,
                workingDirectory: restoredDirectory.path,
                observedPermissionMode: nil
            )
        )
        let invocation = try #require(AgentRestorePlanner(
            executableFileResolver: AgentRestoreExecutableFileResolver()
        ).invocation(
            for: AgentRestoreRequest(
                mode: .resumeAgent,
                kind: snapshot.kind.rawValue,
                checkpointID: snapshot.sessionId,
                source: "session-snapshot",
                workingDirectory: restoredDirectory.path,
                environment: [:],
                launchCommand: snapshot.launchCommand,
                preparedArguments: preparedArguments,
                observedPermissionMode: nil
            ),
            ambientEnvironment: ["PATH": "/usr/bin:/bin"]
        ))
        #expect(invocation.workingDirectory == restoredDirectory.path)
        #expect(invocation.arguments.contains(restoredDirectory.path))
        #expect(!invocation.arguments.contains(savedDirectory.path))
    }

    @Test("restored logical cwd survives physical-path shell reports")
    @MainActor
    func restoredLogicalWorkingDirectorySurvivesResolvedReports() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-9200-logical-cwd-\(UUID().uuidString)", isDirectory: true)
        let physicalDirectory = root.appendingPathComponent("physical", isDirectory: true)
        let logicalDirectory = root.appendingPathComponent("logical", isDirectory: true)
        try fileManager.createDirectory(at: physicalDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: logicalDirectory, withDestinationURL: physicalDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let source = Workspace()
        let sourcePanelId = try #require(source.focusedPanelId)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            .init(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                command: ":",
                cwd: logicalDirectory.path,
                source: "process-detected",
                autoResume: true
            ),
        ])
        let restored = Workspace()
        restored.restoreSessionSnapshot(source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        ))
        let restoredPanelId = try #require(restored.focusedPanelId)

        #expect(restored.updatePanelDirectory(panelId: restoredPanelId, directory: physicalDirectory.path))
        #expect(restored.updatePanelDirectory(panelId: restoredPanelId, directory: physicalDirectory.path))
        #expect(restored.currentDirectory == logicalDirectory.path)
    }

    @Test("remote inline resume strips the saved cwd after retargeting")
    func remoteInlineResumeRemovesStaleSavedWorkingDirectoryOption() throws {
        let savedDirectory = "/home/dev/repo"
        let restoredDirectory = "/home/dev/repo/sub"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "remote-session-9200",
            workingDirectory: savedDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: ["codex", "--cd", savedDirectory],
                workingDirectory: savedDirectory,
                environment: nil,
                capturedAt: 123,
                source: "remote"
            )
        )

        let input = try #require(snapshot.resumeStartupInput(
            useLocalRestoreVerb: false,
            restoringWorkingDirectory: restoredDirectory
        ))
        #expect(input.contains("cd -- '\(restoredDirectory)'"))
        #expect(!input.contains(savedDirectory))
    }

    @Test("remote inline Subrouter resume routes its Codex child through the managed wrapper")
    func remoteInlineSubrouterResumeKeepsCodexHooks() throws {
        let sessionId = "a22293b7-bcef-4707-8439-2f538c8517a4"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionId,
            workingDirectory: "/home/dev/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/opt/custom/codex",
                arguments: ["/opt/custom/codex", "-c", "model_provider=subrouter"],
                workingDirectory: "/home/dev/repo",
                environment: [
                    "CMUX_AGENT_LAUNCH_SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
                    "SUBROUTER_CODEX_BIN": "/opt/custom/codex",
                    "SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
                ],
                capturedAt: 123,
                source: "remote"
            )
        )

        let input = try #require(snapshot.resumeStartupInput(useLocalRestoreVerb: false))

        #expect(input.contains("CMUX_AGENT_RESTORE_LAUNCH=codex:\(sessionId)"), "\(input)")
        #expect(input.contains("SUBROUTER_CODEX_BIN="), "\(input)")
        #expect(input.contains("CMUX_CODEX_WRAPPER_SHIM"), "\(input)")
        #expect(input.contains("CMUX_CUSTOM_CODEX_PATH=/opt/custom/codex"), "\(input)")
    }

    @Test("restored terminal command wrapper sources login files once")
    func restoredTerminalCommandWrapperAvoidsNestedLoginStartup() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-9200-tmux-shell-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let output = root.appendingPathComponent("counts.txt", isDirectory: false)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try """
        export CMUX_9200_ZPROFILE_COUNT=$(( ${CMUX_9200_ZPROFILE_COUNT:-0} + 1 ))

        """.write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try """
        export CMUX_9200_ZLOGIN_COUNT=$(( ${CMUX_9200_ZLOGIN_COUNT:-0} + 1 ))

        """.write(to: home.appendingPathComponent(".zlogin"), atomically: true, encoding: .utf8)
        let command = """
        print -r -- "profile=${CMUX_9200_ZPROFILE_COUNT:-0} login=${CMUX_9200_ZLOGIN_COUNT:-0}" > \(TerminalStartupShellQuoting.singleQuoted(output.path))
        """
        let startupCommand = try #require(OneShotTerminalLauncherStore(
            fileManager: fileManager,
            temporaryDirectory: root
        ).writeStartupCommand(command: command, workingDirectory: nil))
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(startupCommand).map(\.value)
        #expect(Array(words.prefix(3)) == ["/usr/bin/env", "/bin/zsh", "-f"])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", "exec -l \(startupCommand)"]
        process.currentDirectoryURL = root
        process.environment = [
            "HOME": home.path,
            "LOGNAME": NSUserName(),
            "PATH": "/usr/bin:/bin",
            "SHELL": "/bin/zsh",
            "USER": NSUserName(),
            "ZDOTDIR": home.path,
        ]
        let error = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stderr = String(
            data: error.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        #expect(process.terminationStatus == 0, Comment(rawValue: stderr))
        #expect(try String(contentsOf: output, encoding: .utf8) == "profile=1 login=1\n")
    }
}
