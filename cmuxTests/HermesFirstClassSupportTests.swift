import AppKit
import CMUXAgentLaunch
import Foundation
import CmuxWorkspaces
import SQLite3
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Hermes first-class support")
struct HermesFirstClassSupportTests {
    private struct StateRow {
        let id: String
        let cwd: String?
        let source: String
        let startedAt: Double
        let endedAt: Double?

        init(
            _ id: String,
            cwd: String?,
            source: String = "cli",
            startedAt: Double = 10,
            endedAt: Double? = nil
        ) {
            self.id = id
            self.cwd = cwd
            self.source = source
            self.startedAt = startedAt
            self.endedAt = endedAt
        }
    }

    @Test("A running Hermes agent keeps the primary app snapshot decodable")
    func runningHermesAgentAppSnapshotRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hermes-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceID = UUID()
        let panelID = UUID()
        let sessionID = "20260807_192611_076701"
        let workingDirectory = "/tmp/hermes app snapshot"
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "hermes-agent",
            executablePath: "hermes",
            arguments: ["hermes", "--profile", "default", "--tui", "--resume", sessionID],
            workingDirectory: workingDirectory,
            environment: ["HERMES_HOME": "/tmp/hermes-home"],
            capturedAt: 42,
            source: "environment"
        )
        let agent = SessionRestorableAgentSnapshot(
            kind: .hermesAgent,
            sessionId: sessionID,
            workingDirectory: workingDirectory,
            launchCommand: launchCommand,
            registration: .builtInHermes
        )
        let binding = SurfaceResumeBindingSnapshot(
            name: "Hermes Agent",
            kind: RestorableAgentKind.hermesAgent.rawValue,
            command: "hermes --profile default --tui --resume \(sessionID)",
            cwd: workingDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            environment: ["HERMES_HOME": "/tmp/hermes-home"],
            launchCommand: launchCommand,
            autoResume: true,
            approvalPolicy: .auto
        )
        let panel = SessionPanelSnapshot(
            id: panelID,
            type: .terminal,
            title: "Hermes",
            customTitle: nil,
            directory: workingDirectory,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: workingDirectory,
                agent: agent,
                resumeBinding: binding,
                wasAgentRunning: true
            ),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil,
            project: nil
        )
        let blankWorkspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        let hermesWorkspace = SessionWorkspaceSnapshot(
            workspaceId: workspaceID,
            processTitle: "Hermes",
            customTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: workingDirectory,
            focusedPanelId: panelID,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)),
            panels: [panel],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 42,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: SessionTabManagerSnapshot(
                        selectedWorkspaceIndex: 1,
                        workspaces: [blankWorkspace, hermesWorkspace]
                    ),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
                ),
            ]
        )
        let store = SessionSnapshotRepository<AppSessionSnapshot>(
            schemaVersion: SessionSnapshotSchema.currentVersion,
            bundleIdentifier: "com.cmuxterm.tests.hermes-snapshot",
            appSupportDirectory: root
        )
        let fileURL = try #require(store.defaultSnapshotFileURL())

        #expect(store.save(snapshot, fileURL: fileURL))
        let restored = try #require(store.load(fileURL: fileURL))
        let restoredTerminal = try #require(
            restored.windows.first?.tabManager.workspaces.last?.panels.first?.terminal
        )
        #expect(restoredTerminal.agent?.kind == .hermesAgent)
        #expect(restoredTerminal.agent?.sessionId == sessionID)
        #expect(restoredTerminal.agent?.registration == .builtInHermes)
        #expect(restoredTerminal.resumeBinding?.checkpointId == sessionID)
        #expect(restoredTerminal.resumeBinding?.autoResume == true)
        #expect(restoredTerminal.wasAgentRunning == true)
    }

    @Test("Automatic restore repairs a transient Hermes TUI transport ID and retires a missing checkpoint")
    func automaticRestoreRepairsTransientHermesTUIIdentity() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let corruptSessionID = "96dd0dcc"
        let recoveredSessionID = "20260807_192611_076701"
        let workingDirectory = "/tmp/hermes automatic restore"
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "hermes-agent",
            executablePath: "/Users/example/.local/bin/hermes",
            arguments: [
                "/Users/example/.local/bin/hermes",
                "--tui",
                "--provider",
                "xai",
                "--model",
                "grok-4.5",
            ],
            workingDirectory: workingDirectory,
            environment: nil,
            capturedAt: 42,
            source: "environment"
        )
        let corruptAgent = SessionRestorableAgentSnapshot(
            kind: .hermesAgent,
            sessionId: corruptSessionID,
            workingDirectory: workingDirectory,
            launchCommand: launchCommand,
            registration: CmuxVaultAgentRegistration.builtInHermes
        )
        let corruptBinding = SurfaceResumeBindingSnapshot(
            name: "Hermes Agent",
            kind: "hermes-agent",
            command: "'/Users/example/.local/bin/hermes' '--tui' '--resume' '\(corruptSessionID)'",
            cwd: workingDirectory,
            checkpointId: corruptSessionID,
            source: "agent-hook",
            launchCommand: launchCommand,
            autoResume: false,
            approvalPolicy: .auto
        )
        let panel = SessionPanelSnapshot(
            id: surfaceID,
            type: .terminal,
            title: "Hermes",
            customTitle: nil,
            directory: workingDirectory,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: workingDirectory,
                agent: corruptAgent,
                resumeBinding: corruptBinding,
                wasAgentRunning: false
            ),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil,
            project: nil
        )
        let recoveredAgent = SessionRestorableAgentSnapshot(
            kind: .hermesAgent,
            sessionId: recoveredSessionID,
            workingDirectory: workingDirectory,
            launchCommand: launchCommand,
            registration: CmuxVaultAgentRegistration.builtInHermes
        )

        let repaired = Workspace.repairedLegacyHermesSessionPanelSnapshot(
            panel,
            workspaceId: workspaceID,
            recover: { requestedWorkspaceID, requestedSurfaceID, requestedSessionID in
                #expect(requestedWorkspaceID == workspaceID)
                #expect(requestedSurfaceID == surfaceID)
                #expect(requestedSessionID == corruptSessionID)
                return recoveredAgent
            }
        )

        let terminal = try #require(repaired.terminal)
        #expect(terminal.agent?.sessionId == recoveredSessionID)
        #expect(terminal.resumeBinding?.checkpointId == recoveredSessionID)
        #expect(terminal.resumeBinding?.autoResume == true)
        #expect(terminal.managedAgentResumeBinding?.checkpointId == recoveredSessionID)
        #expect(terminal.managedAgentResumeBinding?.autoResume == true)
        #expect(terminal.resumeBinding?.command.contains(recoveredSessionID) == true)
        #expect(terminal.resumeBinding?.command.contains(corruptSessionID) == false)
        #expect(terminal.wasAgentRunning == true)

        let compatibleAgent = try #require(Workspace.restorableAgentForSessionRestore(
            terminal.agent,
            resumeBinding: terminal.resumeBinding
        ))
        #expect(
            compatibleAgent.resumeStartupInput()
                == " \(AgentRestoreLaunch.cliStartupExecutableToken) restore hermes-agent \(recoveredSessionID)\n"
        )

        let missing = Workspace.repairedLegacyHermesSessionPanelSnapshot(
            panel,
            workspaceId: workspaceID,
            recover: { requestedWorkspaceID, requestedSurfaceID, requestedSessionID in
                #expect(requestedWorkspaceID == workspaceID)
                #expect(requestedSurfaceID == surfaceID)
                #expect(requestedSessionID == corruptSessionID)
                return nil
            }
        )
        let missingTerminal = try #require(missing.terminal)
        #expect(missingTerminal.agent == nil)
        #expect(missingTerminal.resumeBinding == nil)
        #expect(missingTerminal.managedAgentResumeBinding == nil)
        #expect(missingTerminal.wasAgentRunning == false)
    }

    @Test("Automatic restore re-arms a durable Hermes checkpoint retired by a legacy launch failure")
    func automaticRestoreRearmsDurableHermesCheckpointAfterLegacyFailure() throws {
        let durableSessionID = "20260807_192611_076701"
        let fixture = try makeFixture {
            [StateRow(durableSessionID, cwd: $0.path, source: "tui")]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transientSessionID = fixture.panelID.uuidString
        let processID = Int(Int32.max) - 9_530
        let processIdentity = AgentPIDProcessIdentity(
            pid: pid_t(processID),
            startSeconds: 700,
            startMicroseconds: 800
        )
        try writeHermesHookStore(
            fixture: fixture,
            sessions: [
                (sessionID: durableSessionID, updatedAt: 101),
                (sessionID: transientSessionID, updatedAt: 102),
            ],
            processID: processID,
            identity: processIdentity,
            executablePath: fixture.hermesExecutable,
            arguments: [fixture.hermesExecutable, "--tui"],
            runtimeStatus: "running",
            agentLifecycle: "running"
        )

        let workingDirectory = fixture.repo.path
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "hermes-agent",
            executablePath: fixture.hermesExecutable,
            arguments: [fixture.hermesExecutable, "--tui"],
            workingDirectory: workingDirectory,
            environment: [
                "HERMES_HOME": fixture.hermesHome.path,
                "CMUX_AGENT_HOOK_STATE_DIR": fixture.root
                    .appendingPathComponent(".cmuxterm", isDirectory: true).path,
            ],
            capturedAt: 100,
            source: "environment"
        )
        let retiredBinding = SurfaceResumeBindingSnapshot(
            name: "Hermes Agent",
            kind: RestorableAgentKind.hermesAgent.rawValue,
            command: "'\(fixture.hermesExecutable)' '--tui' '--resume' '\(durableSessionID)'",
            cwd: workingDirectory,
            checkpointId: durableSessionID,
            source: "agent-hook",
            launchCommand: launchCommand,
            autoResume: false,
            approvalPolicy: .auto
        )
        let retiredPanel = SessionPanelSnapshot(
            id: fixture.panelID,
            type: .terminal,
            title: "Hermes",
            customTitle: nil,
            directory: workingDirectory,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: workingDirectory,
                agent: nil,
                resumeBinding: retiredBinding,
                managedAgentResumeBinding: nil,
                wasAgentRunning: false
            ),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil,
            project: nil
        )

        let repaired = Workspace.repairedLegacyHermesSessionPanelSnapshot(
            retiredPanel,
            workspaceId: fixture.workspaceID
        )
        let terminal = try #require(repaired.terminal)
        let agent = try #require(terminal.agent)
        let resumeBinding = try #require(terminal.resumeBinding)
        let managedBinding = try #require(terminal.managedAgentResumeBinding)

        #expect(agent.kind == .hermesAgent)
        #expect(agent.sessionId == durableSessionID)
        #expect(resumeBinding.checkpointId == durableSessionID)
        #expect(resumeBinding.autoResume == true)
        #expect(managedBinding.checkpointId == durableSessionID)
        #expect(managedBinding.autoResume == true)
        #expect(terminal.wasAgentRunning == true)
        #expect(
            agent.resumeStartupInput()
                == " \(AgentRestoreLaunch.cliStartupExecutableToken) restore hermes-agent \(durableSessionID)\n"
        )

        // Hermes's durable conversation record becomes idle after a completed
        // turn while the TUI transport process remains live. A quit in this
        // state can persist the already-repaired durable binding as retired
        // before its queued restore input starts. The next launch must still
        // re-arm that durable checkpoint from the live transport evidence.
        try writeHermesHookStore(
            fixture: fixture,
            sessions: [
                (sessionID: durableSessionID, updatedAt: 103),
                (sessionID: transientSessionID, updatedAt: 104),
            ],
            processID: processID,
            identity: processIdentity,
            executablePath: fixture.hermesExecutable,
            arguments: [fixture.hermesExecutable, "--tui"],
            runtimeStatusBySessionID: [
                durableSessionID: "idle",
                transientSessionID: "running",
            ],
            agentLifecycleBySessionID: [
                durableSessionID: "idle",
                transientSessionID: "running",
            ]
        )

        let afterCompletedTurn = Workspace.repairedLegacyHermesSessionPanelSnapshot(
            retiredPanel,
            workspaceId: fixture.workspaceID
        )
        let afterCompletedTurnTerminal = try #require(afterCompletedTurn.terminal)
        #expect(afterCompletedTurnTerminal.agent?.sessionId == durableSessionID)
        #expect(afterCompletedTurnTerminal.resumeBinding?.checkpointId == durableSessionID)
        #expect(afterCompletedTurnTerminal.resumeBinding?.autoResume == true)
        #expect(afterCompletedTurnTerminal.managedAgentResumeBinding?.checkpointId == durableSessionID)
        #expect(afterCompletedTurnTerminal.managedAgentResumeBinding?.autoResume == true)
        #expect(afterCompletedTurnTerminal.wasAgentRunning == true)

        try writeHermesHookStore(
            fixture: fixture,
            sessions: [
                (sessionID: durableSessionID, updatedAt: 105),
                (sessionID: transientSessionID, updatedAt: 106),
            ],
            processID: processID,
            identity: processIdentity,
            executablePath: fixture.hermesExecutable,
            arguments: [fixture.hermesExecutable, "--tui"],
            runtimeStatus: "idle",
            agentLifecycle: "idle"
        )

        let completed = Workspace.repairedLegacyHermesSessionPanelSnapshot(
            retiredPanel,
            workspaceId: fixture.workspaceID
        )
        let completedTerminal = try #require(completed.terminal)
        #expect(completedTerminal.agent == nil)
        #expect(completedTerminal.resumeBinding?.autoResume == false)
        #expect(completedTerminal.managedAgentResumeBinding == nil)
        #expect(completedTerminal.wasAgentRunning == false)
    }

    @Test("A bare Hermes process does not claim an uncorrelated active state.db session")
    func bareProcessRejectsUncorrelatedActiveSession() throws {
        let fixture = try makeFixture { repo in
            [
                StateRow("ended-newer", cwd: repo.path, startedAt: 30, endedAt: 40),
                StateRow("live-session", cwd: repo.path, source: "tui", startedAt: 20),
            ]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [hermesProcess(pid: 9_520, workspaceID: fixture.workspaceID, panelID: fixture.panelID)],
            argumentsByPID: [
                9_520: CmuxTopProcessArguments(
                    arguments: [fixture.hermesExecutable, "--tui"],
                    environment: hermesEnvironment(fixture)
                ),
            ]
        )

        #expect(detected.isEmpty)
    }

    @Test("A cached bare Hermes process cannot retain a snapshot without session identity")
    func cachedBareProcessRequiresExplicitSessionIdentity() {
        let executable = "/opt/homebrew/bin/hermes"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .hermesAgent,
            sessionId: "cached-session",
            workingDirectory: "/tmp/hermes repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "hermes-agent",
                executablePath: executable,
                arguments: [executable, "--tui"],
                workingDirectory: "/tmp/hermes repo",
                environment: nil,
                capturedAt: nil,
                source: "process"
            ),
            registration: CmuxVaultAgentRegistration.builtInHermes
        )
        let liveProcess = CmuxTopProcessArguments(
            arguments: [executable, "--tui"],
            environment: ["CMUX_AGENT_LAUNCH_KIND": "hermes-agent"]
        )

        #expect(
            CachedAgentProcessIdentityValidator().currentProcess(liveProcess, matches: snapshot) == false,
            "A long-lived Hermes process can switch sessions without changing PID or bare argv."
        )
    }

    @Test("The installed Python Hermes launcher remains live and restores through cmux")
    func installedPythonLauncherRemainsRestorable() throws {
        let fixture = try makeFixture { [StateRow("python-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pythonExecutable = fixture.hermesHome
            .appendingPathComponent("hermes-agent/venv/bin/python", isDirectory: false)
            .path
        let hermesEntrypoint = fixture.hermesHome
            .appendingPathComponent("hermes-agent/hermes", isDirectory: false)
            .path
        let process = hermesProcess(
            pid: 9_527,
            workspaceID: fixture.workspaceID,
            panelID: fixture.panelID,
            name: "Python",
            path: pythonExecutable
        )

        let liveProcess = CmuxTopProcessArguments(
            arguments: [pythonExecutable, hermesEntrypoint, "--resume", "python-session", "--tui"],
            environment: hermesEnvironment(fixture)
        )
        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [process],
            argumentsByPID: [process.pid: liveProcess]
        )

        let snapshot = try #require(detected.values.first?.snapshot)
        #expect(snapshot.kind == .hermesAgent)
        #expect(snapshot.sessionId == "python-session")
        #expect(snapshot.launchCommand?.executablePath == "hermes")
        #expect(snapshot.launchCommand?.arguments == ["hermes", "--resume", "python-session", "--tui"])
        #expect(snapshot.resumeStartupInput() == " cmux restore hermes-agent python-session\n")
        #expect(CachedAgentProcessIdentityValidator().currentProcess(liveProcess, matches: snapshot))
    }

    @Test("An unrelated Python argument named Hermes is not detected as the agent entrypoint")
    func unrelatedPythonHermesArgumentIsNotDetected() throws {
        let fixture = try makeFixture { [StateRow("unrelated-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pythonExecutable = fixture.root
            .appendingPathComponent("venv/bin/python", isDirectory: false).path
        let unrelatedEntrypoint = fixture.root
            .appendingPathComponent("tools/report.py", isDirectory: false).path
        let unrelatedHermesArgument = fixture.root
            .appendingPathComponent("fixtures/hermes", isDirectory: false).path
        let process = hermesProcess(
            pid: 9_535,
            workspaceID: fixture.workspaceID,
            panelID: fixture.panelID,
            name: "Python",
            path: pythonExecutable
        )
        let liveProcess = CmuxTopProcessArguments(
            arguments: [
                pythonExecutable,
                unrelatedEntrypoint,
                "--fixture", unrelatedHermesArgument,
                "--resume", "unrelated-session",
            ],
            environment: hermesEnvironment(fixture)
        )
        let observed = VaultObservedAgentProcess(
            processName: process.name,
            processPath: process.path,
            arguments: liveProcess.arguments,
            environment: liveProcess.environment
        )
        let registration = CmuxVaultAgentRegistration.builtInHermes

        #expect(registration.detect.matches(observed) == false)
        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [process],
            argumentsByPID: [process.pid: liveProcess]
        )
        #expect(detected.isEmpty)
    }

    @Test("Python interpreter options preserve the exact Hermes entrypoint")
    func pythonInterpreterOptionsPreserveHermesEntrypoint() {
        let observed = VaultObservedAgentProcess(
            processName: "Python",
            processPath: "/tmp/venv/bin/python3",
            arguments: [
                "/tmp/venv/bin/python3",
                "-u", "-X", "dev",
                "/tmp/venv/bin/HERMES-AGENT",
                "--tui", "--resume", "durable-session",
            ],
            environment: [:]
        )
        let registration = CmuxVaultAgentRegistration.builtInHermes

        #expect(registration.detect.matches(observed))
        #expect(registration.detect.usesAlternateMatchWithoutPrimaryMatch(observed))
        #expect(
            registration.detect.alternateLaunchArguments(
                for: observed,
                defaultExecutable: "hermes"
            ) == ["hermes", "--tui", "--resume", "durable-session"]
        )
    }

    @Test(
        "Python-backed Hermes management commands are detected but never restored",
        arguments: ["gateway", "doctor", "update"]
    )
    func installedPythonManagementCommandsAreNotRestorable(command: String) throws {
        let fixture = try makeFixture { [StateRow("management-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pythonExecutable = fixture.hermesHome
            .appendingPathComponent("hermes-agent/venv/bin/python", isDirectory: false)
            .path
        let hermesEntrypoint = fixture.hermesHome
            .appendingPathComponent("hermes-agent/hermes", isDirectory: false)
            .path
        let process = hermesProcess(
            pid: 9_528,
            workspaceID: fixture.workspaceID,
            panelID: fixture.panelID,
            name: "Python",
            path: pythonExecutable
        )
        let liveProcess = CmuxTopProcessArguments(
            arguments: [pythonExecutable, hermesEntrypoint, command],
            environment: hermesEnvironment(fixture)
        )
        let observed = VaultObservedAgentProcess(
            processName: process.name,
            processPath: process.path,
            arguments: liveProcess.arguments,
            environment: liveProcess.environment
        )
        let registration = CmuxVaultAgentRegistration.builtInHermes

        #expect(registration.detect.matches(observed))
        #expect(registration.processDetectedSnapshotIsRestorable(for: observed) == false)
        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [process],
            argumentsByPID: [process.pid: liveProcess]
        )
        #expect(detected.isEmpty)
    }

    @Test(
        "Hermes one-shot commands are detected but never restored",
        arguments: [
            ["-z", "report status"],
            ["-zreport status"],
            ["--oneshot", "report status"],
            ["--oneshot=report status"],
            ["chat", "-q", "report status"],
            ["chat", "-qreport status"],
            ["chat", "--query", "report status"],
            ["chat", "--query=report status"],
        ]
    )
    func oneShotCommandsAreNotRestorable(arguments: [String]) throws {
        let fixture = try makeFixture { [StateRow("one-shot-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let process = hermesProcess(
            pid: 9_529,
            workspaceID: fixture.workspaceID,
            panelID: fixture.panelID
        )
        let liveProcess = CmuxTopProcessArguments(
            arguments: [fixture.hermesExecutable] + arguments,
            environment: hermesEnvironment(fixture)
        )
        let observed = VaultObservedAgentProcess(
            processName: process.name,
            processPath: process.path,
            arguments: liveProcess.arguments,
            environment: liveProcess.environment
        )
        let registration = CmuxVaultAgentRegistration.builtInHermes

        #expect(registration.detect.matches(observed))
        #expect(registration.processDetectedSnapshotIsRestorable(for: observed) == false)
        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [process],
            argumentsByPID: [process.pid: liveProcess]
        )
        #expect(detected.isEmpty)
    }

    @Test("A hook-owned Python Hermes process remains live without state.db inference")
    func hookOwnedPythonProcessRemainsLive() throws {
        let fixture = try makeFixture { [StateRow("hook-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processID = 9_530
        let identity = AgentPIDProcessIdentity(pid: pid_t(processID), startSeconds: 100, startMicroseconds: 200)
        let pythonExecutable = fixture.hermesHome
            .appendingPathComponent("hermes-agent/venv/bin/python", isDirectory: false)
            .path
        let hermesEntrypoint = fixture.hermesHome
            .appendingPathComponent("hermes-agent/hermes", isDirectory: false)
            .path
        try writeHermesHookStore(
            fixture: fixture,
            sessionID: "hook-session",
            processID: processID,
            identity: identity,
            executablePath: fixture.hermesExecutable,
            arguments: [fixture.hermesExecutable, "--tui"]
        )
        let liveProcess = CmuxTopProcessArguments(
            arguments: [pythonExecutable, hermesEntrypoint, "--tui"],
            environment: hermesEnvironment(fixture).merging([
                "CMUX_WORKSPACE_ID": fixture.workspaceID.uuidString,
                "CMUX_SURFACE_ID": fixture.panelID.uuidString,
            ]) { _, incoming in incoming }
        )

        let index = try loadHookBackedHermesIndex(
            fixture: fixture,
            processID: processID,
            identity: identity,
            liveProcess: liveProcess
        )
        let entry = try #require(index.entry(workspaceId: fixture.workspaceID, panelId: fixture.panelID))

        #expect(entry.snapshot.sessionId == "hook-session")
        #expect(entry.processLiveness == .running)
        #expect(entry.agentProcessIDs == [processID])
    }

    @MainActor
    @Test("An idle Python console-script Hermes TUI remains armed for reopen")
    func idlePythonConsoleScriptHermesTUIRemainsArmedForReopen() throws {
        let defaultsName = "cmux-hermes-idle-console-script-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        let panelID = try #require(source.focusedPanelId)
        let sessionID = "20260807_192611_076701"
        let fixture = try makeFixture(
            workspaceID: source.id,
            panelID: panelID
        ) {
            [StateRow(sessionID, cwd: $0.path, source: "tui")]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let processID = Int(Int32.max) - 9_534
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(processID),
            startSeconds: 1_000,
            startMicroseconds: 2_000
        )
        let pythonExecutable = fixture.root
            .appendingPathComponent("venv/bin/python", isDirectory: false).path
        let hermesConsoleScript = fixture.root
            .appendingPathComponent("venv/bin/hermes", isDirectory: false).path
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "hermes-agent",
            executablePath: hermesConsoleScript,
            arguments: [hermesConsoleScript, "--tui", "--resume", sessionID],
            workingDirectory: fixture.repo.path,
            environment: ["HERMES_HOME": fixture.hermesHome.path],
            capturedAt: 42,
            source: "environment"
        )
        try writeHermesHookStore(
            fixture: fixture,
            sessions: [(sessionID: sessionID, updatedAt: 42)],
            processID: processID,
            identity: identity,
            executablePath: hermesConsoleScript,
            arguments: launchCommand.arguments,
            runtimeStatus: "idle",
            agentLifecycle: "idle"
        )
        let liveProcess = CmuxTopProcessArguments(
            arguments: [pythonExecutable, hermesConsoleScript, "--tui", "--resume", sessionID],
            environment: hermesEnvironment(fixture).merging([
                "CMUX_AGENT_LAUNCH_KIND": "hermes-agent",
                "CMUX_WORKSPACE_ID": fixture.workspaceID.uuidString,
                "CMUX_SURFACE_ID": fixture.panelID.uuidString,
            ]) { _, incoming in incoming }
        )
        let process = hermesProcess(
            pid: processID,
            workspaceID: fixture.workspaceID,
            panelID: fixture.panelID,
            name: "Python",
            path: pythonExecutable
        )
        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [process],
            argumentsByPID: [processID: liveProcess]
        )
        let detectedSnapshot = try #require(detected.values.first?.snapshot)
        #expect(detectedSnapshot.kind == .hermesAgent)
        #expect(detectedSnapshot.sessionId == sessionID)
        #expect(detectedSnapshot.registration?.iconAssetName == "AgentIcons/HermesAgent")
        #expect(detectedSnapshot.launchCommand?.executablePath == "hermes")
        #expect(
            detectedSnapshot.launchCommand?.arguments
                == ["hermes", "--tui", "--resume", sessionID]
        )

        let index = try loadHookBackedHermesIndex(
            fixture: fixture,
            processID: processID,
            identity: identity,
            liveProcess: liveProcess
        )
        let entry = try #require(
            index.entry(workspaceId: fixture.workspaceID, panelId: fixture.panelID)
        )
        #expect(entry.lifecycle == .idle)
        #expect(entry.processLiveness == .running)
        #expect(entry.agentProcessIDs == [processID])

        let binding = SurfaceResumeBindingSnapshot(
            name: "Hermes Agent",
            kind: RestorableAgentKind.hermesAgent.rawValue,
            command: "'\(hermesConsoleScript)' '--tui' '--resume' '\(sessionID)'",
            cwd: fixture.repo.path,
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: launchCommand,
            autoResume: true,
            approvalPolicy: .auto
        )
        #expect(source.setSurfaceResumeBinding(binding, panelId: panelID))

        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: index,
            surfaceResumeBindingIndex: .empty,
            currentAgentProcessIdentity: { $0 == processID ? identity : nil },
            agentProcessPresence: { $0 == processID ? .present : .absent }
        )
        let terminal = try #require(snapshot.panels.first?.terminal)
        #expect(terminal.agent?.sessionId == sessionID)
        #expect(terminal.resumeBinding?.autoResume == true)
        #expect(terminal.wasAgentRunning == true)

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restored.focusedPanelId)
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(restoredPanel.surface.debugInitialCommand() == nil)
        #expect(restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
    }

    @Test("Hook indexing replaces a transient Hermes transport ID with its durable process-generation sibling")
    func hookIndexCanonicalizesTransientHermesIdentity() throws {
        let transientSessionID = "96dd0dcc"
        let durableSessionID = "20260807_192611_076701"
        let fixture = try makeFixture {
            [StateRow(durableSessionID, cwd: $0.path, source: "tui")]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processID = 9_533
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(processID),
            startSeconds: 900,
            startMicroseconds: 1_000
        )
        try writeHermesHookStore(
            fixture: fixture,
            sessions: [
                (sessionID: transientSessionID, updatedAt: 50),
                (sessionID: durableSessionID, updatedAt: 40),
            ],
            processID: processID,
            identity: identity,
            executablePath: fixture.hermesExecutable,
            arguments: [fixture.hermesExecutable, "--tui"]
        )
        let liveProcess = CmuxTopProcessArguments(
            arguments: [fixture.hermesExecutable, "--tui"],
            environment: hermesEnvironment(fixture).merging([
                "CMUX_WORKSPACE_ID": fixture.workspaceID.uuidString,
                "CMUX_SURFACE_ID": fixture.panelID.uuidString,
            ]) { _, incoming in incoming }
        )

        let index = try loadHookBackedHermesIndex(
            fixture: fixture,
            processID: processID,
            identity: identity,
            liveProcess: liveProcess
        )
        let entry = try #require(
            index.entry(
                workspaceId: fixture.workspaceID,
                panelId: fixture.panelID
            )
        )

        #expect(entry.snapshot.sessionId == durableSessionID)
        #expect(entry.processLiveness == .running)
    }

    @Test("Quit-time save revalidates a cached Hermes process against the current snapshot")
    func quitTimeSaveRevalidatesCachedHermesProcess() throws {
        let fixture = try makeFixture { [StateRow("cached-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processID = Int(Int32.max) - 9_530
        let identity = AgentPIDProcessIdentity(pid: pid_t(processID), startSeconds: 300, startMicroseconds: 400)
        try writeHermesHookStore(
            fixture: fixture,
            sessionID: "cached-session",
            processID: processID,
            identity: identity,
            executablePath: fixture.hermesExecutable,
            arguments: [fixture.hermesExecutable, "--resume", "cached-session"]
        )
        let cached = try loadHookBackedHermesIndex(
            fixture: fixture,
            processID: processID,
            identity: identity,
            liveProcess: CmuxTopProcessArguments(
                arguments: [fixture.hermesExecutable, "--resume", "cached-session"],
                environment: hermesEnvironment(fixture).merging([
                    "CMUX_WORKSPACE_ID": fixture.workspaceID.uuidString,
                    "CMUX_SURFACE_ID": fixture.panelID.uuidString,
                ]) { _, incoming in incoming }
            )
        )
        #expect(cached.entry(workspaceId: fixture.workspaceID, panelId: fixture.panelID)?.processLiveness == .running)

        let resumeIndexes = ProcessDetectedResumeIndexes.loadSynchronously(
            homeDirectory: fixture.root.path,
            fileManager: .default,
            cachedRestorableAgentIndex: cached
        )
        let revalidated = try #require(
            resumeIndexes.restorableAgentIndex.entry(
                workspaceId: fixture.workspaceID,
                panelId: fixture.panelID
            )
        )

        #expect(revalidated.processLiveness == .exited)
        #expect(revalidated.agentProcessIDs.isEmpty)
    }

    @Test("Quit watchdog fallback uses the cached Hermes index without process revalidation")
    func quitWatchdogFallbackUsesCachedHermesIndexWithoutProcessRevalidation() throws {
        let fixture = try makeFixture { [StateRow("watchdog-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processID = Int(Int32.max) - 9_532
        let identity = AgentPIDProcessIdentity(pid: pid_t(processID), startSeconds: 700, startMicroseconds: 800)
        try writeHermesHookStore(
            fixture: fixture,
            sessionID: "watchdog-session",
            processID: processID,
            identity: identity,
            executablePath: fixture.hermesExecutable,
            arguments: [fixture.hermesExecutable, "--resume", "watchdog-session"]
        )
        let cached = try loadHookBackedHermesIndex(
            fixture: fixture,
            processID: processID,
            identity: identity,
            liveProcess: CmuxTopProcessArguments(
                arguments: [fixture.hermesExecutable, "--resume", "watchdog-session"],
                environment: hermesEnvironment(fixture).merging([
                    "CMUX_WORKSPACE_ID": fixture.workspaceID.uuidString,
                    "CMUX_SURFACE_ID": fixture.panelID.uuidString,
                ]) { _, incoming in incoming }
            )
        )

        let resumeIndexes = ProcessDetectedResumeIndexes.cached(
            restorableAgentIndex: cached
        )
        let preserved = try #require(
            resumeIndexes.restorableAgentIndex.entry(
                workspaceId: fixture.workspaceID,
                panelId: fixture.panelID
            )
        )

        #expect(preserved.processLiveness == .running)
        #expect(preserved.agentProcessIDs == [processID])
    }

    @Test("Fresh synchronous lifecycle load discovers a Hermes hook session missing from the cache")
    func freshSynchronousLifecycleLoadDiscoversNewHermesSession() throws {
        let fixture = try makeFixture { [StateRow("new-hook-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processID = Int(Int32.max) - 9_531
        let identity = AgentPIDProcessIdentity(pid: pid_t(processID), startSeconds: 500, startMicroseconds: 600)
        try writeHermesHookStore(
            fixture: fixture,
            sessionID: "new-hook-session",
            processID: processID,
            identity: identity,
            executablePath: fixture.hermesExecutable,
            arguments: [fixture.hermesExecutable, "--resume", "new-hook-session"]
        )

        let staleResumeIndexes = ProcessDetectedResumeIndexes.loadSynchronously(
            homeDirectory: fixture.root.path,
            fileManager: .default,
            cachedRestorableAgentIndex: .empty
        )
        #expect(
            staleResumeIndexes.restorableAgentIndex.entry(
                workspaceId: fixture.workspaceID,
                panelId: fixture.panelID
            ) == nil
        )

        let freshResumeIndexes = ProcessDetectedResumeIndexes.loadFreshSynchronously(
            homeDirectory: fixture.root.path,
            fileManager: .default
        )
        let discovered = try #require(
            freshResumeIndexes.restorableAgentIndex.entry(
                workspaceId: fixture.workspaceID,
                panelId: fixture.panelID
            )
        )
        #expect(discovered.snapshot.kind == .hermesAgent)
        #expect(discovered.snapshot.sessionId == "new-hook-session")
    }

    @Test(
        "Explicit Hermes resume flags win over ambiguous cwd lookup",
        arguments: [
            ["--resume", "explicit-session"],
            ["--resume=explicit-session"],
            ["-r", "explicit-session"],
            ["-r=explicit-session"],
        ]
    )
    func explicitResumeFlagsWin(arguments: [String]) throws {
        let fixture = try makeFixture { repo in
            [
                StateRow("explicit-session", cwd: repo.path, startedAt: 10),
                StateRow("other-active-session", cwd: repo.path, startedAt: 20),
            ]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let processArguments = [fixture.hermesExecutable] + arguments + ["--tui"]
        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [hermesProcess(pid: 9_521, workspaceID: fixture.workspaceID, panelID: fixture.panelID)],
            argumentsByPID: [
                9_521: CmuxTopProcessArguments(
                    arguments: processArguments,
                    environment: hermesEnvironment(fixture)
                ),
            ]
        )

        #expect(detected.values.first?.snapshot.kind == .hermesAgent)
        #expect(detected.values.first?.snapshot.sessionId == "explicit-session")
    }

    @Test("A bare Hermes process fails closed when active state.db rows are ambiguous")
    func bareProcessRejectsAmbiguousActiveSessions() throws {
        let fixture = try makeFixture { repo in
            [
                StateRow("active-a", cwd: repo.path, startedAt: 10),
                StateRow("active-b", cwd: repo.path, startedAt: 20),
            ]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [hermesProcess(pid: 9_522, workspaceID: fixture.workspaceID, panelID: fixture.panelID)],
            argumentsByPID: [
                9_522: CmuxTopProcessArguments(
                    arguments: [fixture.hermesExecutable],
                    environment: hermesEnvironment(fixture)
                ),
            ]
        )

        #expect(detected.isEmpty)
    }

    @Test("Two bare Hermes panes in one cwd do not claim the same state.db session")
    func coLocatedBareProcessesDoNotShareOneSession() throws {
        let secondPanelID = UUID()
        let fixture = try makeFixture { [StateRow("only-active", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processes = [
            hermesProcess(pid: 9_523, workspaceID: fixture.workspaceID, panelID: fixture.panelID),
            hermesProcess(pid: 9_524, workspaceID: fixture.workspaceID, panelID: secondPanelID),
        ]
        let launch = CmuxTopProcessArguments(
            arguments: [fixture.hermesExecutable],
            environment: hermesEnvironment(fixture)
        )

        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: processes,
            argumentsByPID: [9_523: launch, 9_524: launch]
        )

        #expect(detected.isEmpty)
    }

    @Test("An explicit Hermes owner prevents a bare pane from claiming the same state.db session")
    func explicitAndBareProcessesDoNotShareOneSession() throws {
        let explicitPanelID = UUID()
        let fixture = try makeFixture { [StateRow("explicit-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [
                hermesProcess(pid: 9_525, workspaceID: fixture.workspaceID, panelID: explicitPanelID),
                hermesProcess(pid: 9_526, workspaceID: fixture.workspaceID, panelID: fixture.panelID),
            ],
            argumentsByPID: [
                9_525: CmuxTopProcessArguments(
                    arguments: [fixture.hermesExecutable, "--resume", "explicit-session"],
                    environment: hermesEnvironment(fixture)
                ),
                9_526: CmuxTopProcessArguments(
                    arguments: [fixture.hermesExecutable],
                    environment: hermesEnvironment(fixture)
                ),
            ]
        )

        #expect(detected.count == 1)
        #expect(detected[.init(workspaceId: fixture.workspaceID, panelId: explicitPanelID)]?.snapshot.sessionId == "explicit-session")
        #expect(detected[.init(workspaceId: fixture.workspaceID, panelId: fixture.panelID)] == nil)
    }

    @Test("Session index entries preserve Hermes cwd for filtering and resume")
    func sessionIndexPreservesCwd() throws {
        let fixture = try makeFixture { [StateRow("indexed-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let outcome = SessionIndexStore.loadHermesAgentEntriesForTesting(
            stateDBPath: fixture.stateDB.path,
            cwdFilter: fixture.repo.path
        )
        let entry = try #require(outcome.entries.first)

        #expect(outcome.errors.isEmpty)
        #expect(entry.sessionId == "indexed-session")
        #expect(entry.cwd == fixture.repo.path)
        let expectedCWD = TerminalStartupShellQuoting.singleQuoted(fixture.repo.path)
        let expectedHome = SessionEntry.shellQuote(fixture.hermesHome.path)
        let expectedResume = AgentResumeArgv.portableHermesResumeShellCommand(
            posixCommand: "env HERMES_HOME=\(expectedHome) \(AgentResumeArgv.hermesWrapperShellExecutableToken) --profile default --resume indexed-session --model test-model"
        )
        #expect(
            entry.copyResumeCommand
                == "cd -- \(expectedCWD) 2>/dev/null && \(expectedResume)"
        )
    }

    @Test("Default Hermes Vault resumes stay on the indexed profile")
    func defaultHermesVaultResumePinsIndexedProfile() throws {
        let root = try temporaryDirectory(prefix: "cmux-hermes-vault-resume")
        defer { try? FileManager.default.removeItem(at: root) }
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let launcher = binDirectory.appendingPathComponent("hermes", isDirectory: false)
        try """
        #!/bin/sh
        profile=
        previous=
        for argument in "$@"; do
          if [ "$previous" = "--profile" ]; then
            profile="$argument"
          fi
          previous="$argument"
        done
        if [ "$HERMES_HOME" != "$EXPECTED_HERMES_HOME" ]; then
          echo "wrong Hermes home"
          exit 41
        fi
        if [ "$profile" != "default" ]; then
          echo "wrong Hermes profile"
          exit 42
        fi
        printf '%s\n' "$@"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let entry = SessionEntry(
            id: "hermes-agent:indexed-session",
            agent: .hermesAgent,
            sessionId: "indexed-session",
            title: "Indexed session",
            cwd: nil,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 0),
            fileURL: nil,
            specifics: .hermesAgent(source: "tui", model: nil, hermesHome: nil)
        )
        let expectedHome = HermesAgentSessionResolver.hermesHome(env: ["HOME": NSHomeDirectory()])
        let resumeCommand = try #require(entry.copyResumeCommand)
        let result = try runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", resumeCommand],
            environment: [
                "HOME": NSHomeDirectory(),
                "HERMES_HOME": root.appendingPathComponent("wrong-profile").path,
                "EXPECTED_HERMES_HOME": expectedHome,
                "PATH": "\(binDirectory.path):/usr/bin:/bin",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.split(separator: "\n").map(String.init) == [
            "--profile", "default", "--tui", "--resume", "indexed-session",
        ])
    }

    @Test("Hermes Vault resume uses the managed wrapper instead of a conflicting PATH install")
    func hermesVaultResumeUsesManagedWrapper() throws {
        let result = try hermesVaultManagedWrapperProbe()

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(
            result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                == "managed|--profile|default|--tui|--resume|indexed-session|--model|test-model"
        )
    }

    private func hermesVaultManagedWrapperProbe() throws -> (status: Int32, output: String) {
        let root = try temporaryDirectory(prefix: "cmux-hermes-vault-wrapper")
        defer { try? FileManager.default.removeItem(at: root) }
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let hermesHome = root.appendingPathComponent("hermes-home", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)

        let conflictingHermes = binDirectory.appendingPathComponent("hermes", isDirectory: false)
        try """
        #!/bin/sh
        echo 'Error: session not found'
        exit 47
        """.write(to: conflictingHermes, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: conflictingHermes.path
        )

        let managedWrapper = root.appendingPathComponent("managed-hermes", isDirectory: false)
        try """
        #!/bin/sh
        printf 'managed'
        for argument in "$@"; do
          printf '|%s' "$argument"
        done
        printf '\n'
        """.write(to: managedWrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: managedWrapper.path
        )

        let entry = SessionEntry(
            id: "hermes-agent:indexed-session",
            agent: .hermesAgent,
            sessionId: "indexed-session",
            title: "Indexed session",
            cwd: nil,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 0),
            fileURL: nil,
            specifics: .hermesAgent(
                source: "tui",
                model: "test-model",
                hermesHome: hermesHome.path
            )
        )
        let resumeCommand = try #require(entry.copyResumeCommand)
        return try runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", resumeCommand],
            environment: [
                "CMUX_HERMES_AGENT_WRAPPER_SHIM": managedWrapper.path,
                "PATH": "\(binDirectory.path):/usr/bin:/bin",
            ]
        )
    }

    @Test("Named Hermes Vault resumes keep their indexed profile")
    func namedHermesVaultResumeKeepsIndexedProfile() {
        let entry = SessionEntry(
            id: "hermes-agent:indexed-session",
            agent: .hermesAgent,
            sessionId: "indexed-session",
            title: "Indexed session",
            cwd: nil,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 0),
            fileURL: nil,
            specifics: .hermesAgent(
                source: "tui",
                model: nil,
                hermesHome: "/tmp/hermes/profiles/coder"
            )
        )

        let expectedResume = AgentResumeArgv.portableHermesResumeShellCommand(
            posixCommand: "env HERMES_HOME=/tmp/hermes/profiles/coder \(AgentResumeArgv.hermesWrapperShellExecutableToken) --tui --resume indexed-session"
        )
        #expect(entry.copyResumeCommand == expectedResume)
    }

    @MainActor
    @Test("Indexed Hermes sessions form a visible Vault section")
    func indexedSessionsFormVisibleVaultSection() throws {
        let fixture = try makeFixture {
            [StateRow("visible-session", cwd: $0.path, startedAt: 42)]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outcome = SessionIndexStore.loadHermesAgentEntriesForTesting(
            stateDBPath: fixture.stateDB.path
        )
        let entry = try #require(outcome.entries.first)
        let defaults = UserDefaults.standard
        let groupingKey = "sessionIndex.grouping"
        let agentOrderKey = "sessionIndex.agentOrder"
        let previousGrouping = defaults.object(forKey: groupingKey)
        let previousAgentOrder = defaults.object(forKey: agentOrderKey)
        defer {
            restoreDefaultsValue(previousGrouping, key: groupingKey, defaults: defaults)
            restoreDefaultsValue(previousAgentOrder, key: agentOrderKey, defaults: defaults)
        }
        defaults.set(SessionGrouping.agent.rawValue, forKey: groupingKey)
        defaults.set([SessionAgent.hermesAgent.rawValue], forKey: agentOrderKey)

        let store = SessionIndexStore()
        store.replaceEntriesForTesting([entry])
        let section = try #require(store.sectionsForCurrentGrouping().first)

        #expect(section.key == .agent(.hermesAgent))
        #expect(section.title == "Hermes Agent")
        #expect(section.icon == .agent(.hermesAgent))
        #expect(section.entries.map(\.sessionId) == ["visible-session"])
        #expect(SessionAgent.hermesAgent.assetName == "AgentIcons/HermesAgent")
        #expect(CmuxVaultAgentRegistration.builtInHermes.iconAssetName == "AgentIcons/HermesAgent")
    }

    @Test("Hermes loads the official desktop icon from the compiled asset catalog")
    func officialDesktopIconAsset() throws {
        let assetName = try #require(SessionAgent.hermesAgent.assetName)
        let image = try #require(
            Bundle.main.image(forResource: assetName)
                ?? NSImage(named: NSImage.Name(assetName))
        )
        var proposedRect = NSRect(origin: .zero, size: image.size)
        let rendered = try #require(
            image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        )

        #expect(rendered.width == 1_024)
        #expect(rendered.height == 1_024)
    }

    @Test("User-configured detectors take precedence over the built-in Hermes detector")
    func userDetectorTakesPrecedence() throws {
        let fixture = try makeFixture { [StateRow("built-in-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let builtInRegistry = CmuxVaultAgentRegistry.load(
            homeDirectory: fixture.root.path,
            environment: ["HOME": fixture.root.path],
            fileManager: .default
        )
        let builtInHermes = try #require(builtInRegistry.registration(id: "hermes-agent"))
        let custom = CmuxVaultAgentRegistration(
            id: "team-hermes",
            name: "Team Hermes",
            detect: CmuxVaultAgentDetectRule(processNames: ["hermes"]),
            sessionIdSource: .argvOption("--team-session"),
            resumeCommand: "{{executable}} --team-session {{sessionId}}"
        )
        let registry = CmuxVaultAgentRegistry(registrations: [builtInHermes, custom])
        let process = hermesProcess(pid: 9_525, workspaceID: fixture.workspaceID, panelID: fixture.panelID)

        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [process],
                sampledAt: Date(timeIntervalSince1970: 0),
                includesProcessDetails: true
            ),
            capturedAt: 42,
            processArgumentsProvider: { pid in
                guard pid == process.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [fixture.hermesExecutable, "--team-session", "team-session-1"],
                    environment: self.hermesEnvironment(fixture)
                )
            }
        )

        #expect(detected.values.first?.snapshot.kind == .custom("team-hermes"))
        #expect(detected.values.first?.snapshot.sessionId == "team-session-1")
    }

    @Test("Hermes hook install migrates consent to ambient per-launch dispatch")
    func hookInstallUsesAmbientDispatchAndConsent() throws {
        let root = try temporaryDirectory(prefix: "cmux-hermes-hooks")
        defer { try? FileManager.default.removeItem(at: root) }
        let hermesHome = root.appendingPathComponent("hermes-home", isDirectory: true)
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        let pinnedCLI = root.appendingPathComponent("cmux pinned cli", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: pinnedCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pinnedCLI.path)
        let socketPath = root.appendingPathComponent("cmux-debug-hermes-first-class.sock").path
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: HermesFirstClassBundleToken.self)
        let allowlistURL = hermesHome.appendingPathComponent("shell-hooks-allowlist.json")
        let legacyCommand = #"sh -c 'cmux_cli=cmux; "$cmux_cli" hooks hermes-agent prompt-submit'"#
        let userCommand = "echo user-owned Hermes hook"
        let existingAllowlist = try JSONSerialization.data(
            withJSONObject: [
                "approvals": [
                    [
                        "event": "pre_llm_call",
                        "command": legacyCommand,
                        "approved_at": "2026-01-01T00:00:00Z",
                    ],
                    [
                        "event": "pre_tool_call",
                        "command": userCommand,
                        "scope": "user",
                    ],
                ],
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try existingAllowlist.write(to: allowlistURL, options: .atomic)

        let result = try runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "hermes-agent", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "HERMES_HOME": hermesHome.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_BUNDLED_CLI_PATH": pinnedCLI.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        let config = try String(
            contentsOf: hermesHome.appendingPathComponent("config.yaml"),
            encoding: .utf8
        )
        let allowlistData = try Data(
            contentsOf: allowlistURL
        )
        let allowlist = try #require(
            JSONSerialization.jsonObject(with: allowlistData) as? [String: Any]
        )
        let approvals = try #require(allowlist["approvals"] as? [[String: Any]])
        let commands = approvals.compactMap { $0["command"] as? String }
        let cmuxCommands = commands.filter {
            $0.contains("cmux-hermes-agent-hook-v2") || $0.contains("hooks hermes-agent ")
        }

        #expect(commands.count == approvals.count)
        #expect(commands.contains(userCommand))
        #expect(!commands.contains(legacyCommand))
        #expect(!cmuxCommands.isEmpty)
        #expect(cmuxCommands.allSatisfy { !$0.contains("cmux-hermes-agent-hook-v2") })
        #expect(cmuxCommands.allSatisfy { !$0.contains(pinnedCLI.path) })
        #expect(cmuxCommands.allSatisfy { !$0.contains(socketPath) })
        #expect(cmuxCommands.allSatisfy { $0.contains("CMUX_BUNDLED_CLI_PATH") })
        #expect(cmuxCommands.allSatisfy { $0.contains("CMUX_SOCKET_PATH") })
        #expect(!config.contains("cmux-hermes-agent-hook-v2"))
        #expect(!config.contains(pinnedCLI.path))
        #expect(!config.contains(socketPath))
        #expect(config.contains("CMUX_BUNDLED_CLI_PATH"))
        #expect(config.contains("CMUX_SOCKET_PATH"))
    }

    @Test("Hermes hook install creates a fresh home without a pinned cmux target")
    func hookInstallCreatesMissingHomeWithAmbientDispatch() throws {
        let root = try temporaryDirectory(prefix: "cmux-hermes-hooks-no-target")
        defer { try? FileManager.default.removeItem(at: root) }
        let hermesHome = root.appendingPathComponent("hermes-home", isDirectory: true)
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: HermesFirstClassBundleToken.self)
        let configURL = hermesHome.appendingPathComponent("config.yaml")
        let allowlistURL = hermesHome.appendingPathComponent("shell-hooks-allowlist.json")
        let allowlistLockURL = hermesHome.appendingPathComponent("shell-hooks-allowlist.json.lock")

        let result = try runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "hermes-agent", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "HERMES_HOME": hermesHome.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(FileManager.default.fileExists(atPath: configURL.path))
        #expect(FileManager.default.fileExists(atPath: allowlistURL.path))
        #expect(FileManager.default.fileExists(atPath: allowlistLockURL.path))
        let config = try String(contentsOf: configURL, encoding: .utf8)
        #expect(config.contains("CMUX_BUNDLED_CLI_PATH"))
        #expect(config.contains("CMUX_SOCKET_PATH"))
    }

    @Test("Hermes hook install reports directory creation failures accurately")
    func hookInstallReportsDirectoryCreationFailure() throws {
        let root = try temporaryDirectory(prefix: "cmux-hermes-hooks-create-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: HermesFirstClassBundleToken.self)
        let blockedHermesHome = "/dev/null/cmux-hermes-hooks-\(UUID().uuidString)"

        let result = try runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "hermes-agent", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "HERMES_HOME": blockedHermesHome,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("could not create the hooks directory at \(blockedHermesHome)"))
        #expect(result.output.contains("Check the parent directory permissions and try again."))
        #expect(!result.output.contains("conflicting file"))
    }

    @Test("Hook setup skips an unroutable pinned agent and continues with ambient agents")
    func hookSetupContinuesAfterPinnedTargetFailure() throws {
        let root = try temporaryDirectory(prefix: "cmux-hermes-hooks-setup")
        defer { try? FileManager.default.removeItem(at: root) }
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let hermesHome = root.appendingPathComponent("hermes-home", isDirectory: true)
        let grokHome = root.appendingPathComponent("grok-home", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        for name in ["grok", "hermes"] {
            let executable = binDirectory.appendingPathComponent(name, isDirectory: false)
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: HermesFirstClassBundleToken.self)
        let result = try runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "setup", "--yes"],
            environment: [
                "HOME": root.path,
                "HERMES_HOME": hermesHome.path,
                "GROK_HOME": grokHome.path,
                "PATH": "\(binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("grok"))
        #expect(result.output.contains("Open a cmux workspace and run this command again."))
        #expect(!result.output.contains("CMUX_SOCKET_PATH"))
        #expect(!result.output.contains("CMUX_TAG"))
        #expect(result.output.contains("hermes-agent:"))
        #expect(FileManager.default.fileExists(
            atPath: hermesHome.appendingPathComponent("config.yaml", isDirectory: false).path
        ))
    }

    private struct Fixture {
        let root: URL
        let hermesHome: URL
        let stateDB: URL
        let repo: URL
        let workspaceID: UUID
        let panelID: UUID
        let hermesExecutable: String
    }

    private func makeFixture(
        workspaceID: UUID = UUID(),
        panelID: UUID = UUID(),
        rows: (URL) -> [StateRow]
    ) throws -> Fixture {
        let root = try temporaryDirectory(prefix: "cmux-hermes-first-class")
        let hermesHome = root.appendingPathComponent("hermes-home", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let stateDB = hermesHome.appendingPathComponent("state.db", isDirectory: false)
        try writeStateDB(at: stateDB, rows: rows(repo))
        return Fixture(
            root: root,
            hermesHome: hermesHome,
            stateDB: stateDB,
            repo: repo,
            workspaceID: workspaceID,
            panelID: panelID,
            hermesExecutable: "/usr/local/bin/hermes"
        )
    }

    private func detectedHermesSnapshots(
        fixture: Fixture,
        processes: [CmuxTopProcessInfo],
        argumentsByPID: [Int: CmuxTopProcessArguments]
    ) throws -> [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry] {
        let registry = CmuxVaultAgentRegistry.load(
            homeDirectory: fixture.root.path,
            environment: ["HOME": fixture.root.path],
            fileManager: .default
        )
        _ = try #require(registry.registration(id: "hermes-agent"))
        return RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: processes,
                sampledAt: Date(timeIntervalSince1970: 0),
                includesProcessDetails: true
            ),
            capturedAt: 42,
            processArgumentsProvider: { argumentsByPID[$0] }
        )
    }

    private func hermesProcess(
        pid: Int,
        workspaceID: UUID,
        panelID: UUID,
        name: String = "hermes",
        path: String = "/usr/local/bin/hermes"
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: 1,
            name: name,
            path: path,
            ttyDevice: nil,
            cmuxWorkspaceID: workspaceID,
            cmuxSurfaceID: panelID,
            cmuxAttributionReason: "cmux-test",
            processGroupID: nil,
            terminalProcessGroupID: nil,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 1
        )
    }

    private func hermesEnvironment(_ fixture: Fixture) -> [String: String] {
        [
            "HERMES_HOME": fixture.hermesHome.path,
            "CMUX_AGENT_LAUNCH_CWD": fixture.repo.path,
            "PWD": fixture.repo.path,
        ]
    }

    private func writeHermesHookStore(
        fixture: Fixture,
        sessionID: String,
        processID: Int,
        identity: AgentPIDProcessIdentity,
        executablePath: String,
        arguments: [String]
    ) throws {
        try writeHermesHookStore(
            fixture: fixture,
            sessions: [(sessionID: sessionID, updatedAt: 42)],
            processID: processID,
            identity: identity,
            executablePath: executablePath,
            arguments: arguments
        )
    }

    private func writeHermesHookStore(
        fixture: Fixture,
        sessions: [(sessionID: String, updatedAt: Double)],
        processID: Int,
        identity: AgentPIDProcessIdentity,
        executablePath: String,
        arguments: [String],
        runtimeStatus: String? = nil,
        agentLifecycle: String? = nil,
        runtimeStatusBySessionID: [String: String] = [:],
        agentLifecycleBySessionID: [String: String] = [:]
    ) throws {
        let stateDirectory = fixture.root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        var sessionObjects: [String: Any] = [:]
        for session in sessions {
            var record: [String: Any] = [
                "sessionId": session.sessionID,
                "workspaceId": fixture.workspaceID.uuidString,
                "surfaceId": fixture.panelID.uuidString,
                "cwd": fixture.repo.path,
                "pid": processID,
                "pidStartSeconds": identity.startSeconds,
                "pidStartMicroseconds": identity.startMicroseconds,
                "isRestorable": true,
                "startedAt": 10,
                "updatedAt": session.updatedAt,
                "launchCommand": [
                    "launcher": "hermes-agent",
                    "executablePath": executablePath,
                    "arguments": arguments,
                    "workingDirectory": fixture.repo.path,
                    "environment": ["HERMES_HOME": fixture.hermesHome.path],
                    "capturedAt": session.updatedAt,
                    "source": "environment",
                ],
            ]
            if let runtimeStatus = runtimeStatusBySessionID[session.sessionID] ?? runtimeStatus {
                record["runtimeStatus"] = runtimeStatus
            }
            if let agentLifecycle = agentLifecycleBySessionID[session.sessionID] ?? agentLifecycle {
                record["agentLifecycle"] = agentLifecycle
            }
            sessionObjects[session.sessionID] = record
        }
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": sessionObjects,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: stateDirectory.appendingPathComponent("hermes-agent-hook-sessions.json", isDirectory: false),
            options: .atomic
        )
    }

    private func loadHookBackedHermesIndex(
        fixture: Fixture,
        processID: Int,
        identity: AgentPIDProcessIdentity,
        liveProcess: CmuxTopProcessArguments
    ) throws -> RestorableAgentSessionIndex {
        let registry = CmuxVaultAgentRegistry.load(
            homeDirectory: fixture.root.path,
            environment: ["HOME": fixture.root.path],
            fileManager: .default
        )
        _ = try #require(registry.registration(id: "hermes-agent"))
        return RestorableAgentSessionIndex.load(
            homeDirectory: fixture.root.path,
            fileManager: .default,
            registry: registry,
            detectedSnapshots: [:],
            processArgumentsProvider: { $0 == processID ? liveProcess : nil },
            processPresenceProvider: { $0 == processID ? .present : .absent },
            processIdentityProvider: { $0 == processID ? identity : nil }
        )
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func restoreDefaultsValue(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func writeStateDB(at url: URL, rows: [StateRow]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw HermesFirstClassTestError.sqlite("open failed")
        }
        defer { sqlite3_close(database) }
        try execute(database, sql: """
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          source TEXT NOT NULL,
          model TEXT,
          started_at REAL NOT NULL,
          ended_at REAL,
          title TEXT,
          cwd TEXT
        );
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT,
          tool_name TEXT,
          tool_calls TEXT,
          timestamp REAL NOT NULL
        );
        """)
        for row in rows {
            try execute(
                database,
                sql: """
                INSERT INTO sessions (id, source, model, started_at, ended_at, title, cwd)
                VALUES (
                  \(sqlLiteral(row.id)),
                  \(sqlLiteral(row.source)),
                  'test-model',
                  \(row.startedAt),
                  \(row.endedAt.map { String($0) } ?? "NULL"),
                  \(sqlLiteral(row.id)),
                  \(row.cwd.map(sqlLiteral) ?? "NULL")
                );
                """
            )
        }
    }

    private func execute(_ database: OpaquePointer, sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error \(result)"
            sqlite3_free(error)
            throw HermesFirstClassTestError.sqlite(message)
        }
    }

    private func sqlLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}

private final class HermesFirstClassBundleToken {}

private enum HermesFirstClassTestError: Error {
    case sqlite(String)
}
