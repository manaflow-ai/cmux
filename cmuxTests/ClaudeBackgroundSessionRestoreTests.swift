import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A cmux pane viewing a Claude Code background session (`claude attach <id>`,
/// hosted by Claude's `bg-pty-host`/`bg-spare` daemon) used to come back as a
/// bare shell after a cmux update: the hook binding was manual
/// (`autoResume: false`, `wasAgentRunning: false`) and `claude --resume` would
/// have contended with the daemon's live writer. Restore must reattach instead.
@MainActor
@Suite("Claude background session restore", .serialized)
struct ClaudeBackgroundSessionRestoreTests {
    private let sessionID = "884a7be7-5a7c-4d54-838e-423426a31aaf"
    private let jobID = "884a7be7"
    private let executable = "/Users/me/.local/bin/claude"

    private struct Fixture {
        let root: URL
        let configDirectory: URL
        let workingDirectory: URL
        let defaults: UserDefaults
        let defaultsName: String
        let daemonProcess: Process

        var daemonProcessID: Int { Int(daemonProcess.processIdentifier) }

        func registerSession(
            kind: String,
            sessionID: String,
            jobID: String?,
            processID: Int,
            procStart: String? = nil
        ) throws {
            var record: [String: Any] = [
                "pid": processID,
                "sessionId": sessionID,
                "kind": kind,
                "name": "Recent cmux sessions recap",
                "pidDomain": "darwin",
            ]
            if let jobID { record["jobId"] = jobID }
            // Claude records its process start (UTC, ctime layout) so a reused
            // PID cannot pass for the daemon's process.
            if let procStart = procStart ?? ClaudeBackgroundSessionRegistry.processStartSeconds(processID)
                .map(ClaudeBackgroundSessionRegistry.formatProcStart) {
                record["procStart"] = procStart
            }
            try JSONSerialization.data(withJSONObject: record)
                .write(to: configDirectory
                    .appendingPathComponent("sessions", isDirectory: true)
                    .appendingPathComponent("\(processID).json"))
        }

        func cleanup() {
            if daemonProcess.isRunning {
                daemonProcess.terminate()
                daemonProcess.waitUntilExit()
            }
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-bg-restore-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("claude-proxy", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let defaultsName = "cmux-claude-bg-restore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        // Stands in for the daemon's `claude bg-spare` process.
        let daemonProcess = Process()
        daemonProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        daemonProcess.arguments = ["60"]
        try daemonProcess.run()
        return Fixture(
            root: root,
            configDirectory: configDirectory,
            workingDirectory: workingDirectory,
            defaults: defaults,
            defaultsName: defaultsName,
            daemonProcess: daemonProcess
        )
    }

    private func environment(_ fixture: Fixture) -> [String: String] {
        [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:31415",
            "CLAUDE_CONFIG_DIR": fixture.configDirectory.path,
            "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV": "1",
            "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS": "ANTHROPIC_BASE_URL,CLAUDE_CONFIG_DIR",
        ]
    }

    private func launchCommand(_ fixture: Fixture) -> AgentLaunchCommandSnapshot {
        AgentLaunchCommandSnapshot(
            launcher: "claude",
            executablePath: executable,
            arguments: [executable],
            workingDirectory: fixture.workingDirectory.path,
            environment: [
                "ANTHROPIC_BASE_URL": "http://127.0.0.1:31415",
                "CLAUDE_CONFIG_DIR": fixture.configDirectory.path,
            ],
            capturedAt: 1_791_158_107,
            source: "environment"
        )
    }

    /// The panel exactly as cmux NIGHTLY saved it for session 884a7be7.
    private func hookBinding(_ fixture: Fixture, autoResume: Bool) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "Claude Code",
            kind: "claude",
            command: "claude --resume \(sessionID) --permission-mode auto",
            cwd: fixture.workingDirectory.path,
            checkpointId: sessionID,
            source: "agent-hook",
            environment: environment(fixture),
            launchCommand: launchCommand(fixture),
            permissionMode: "auto",
            autoResume: autoResume,
            approvalPolicy: .auto,
            updatedAt: 1_791_483_501
        )
    }

    private func agent(_ fixture: Fixture) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionID,
            workingDirectory: fixture.workingDirectory.path,
            launchCommand: launchCommand(fixture)
        )
    }

    private func viewer(_ fixture: Fixture) -> ClaudeBackgroundSessionViewer {
        ClaudeBackgroundSessionViewer(
            reference: jobID,
            launchArguments: [executable],
            environment: [
                "ANTHROPIC_BASE_URL": "http://127.0.0.1:31415",
                "CLAUDE_CONFIG_DIR": fixture.configDirectory.path,
            ]
        )
    }

    private struct Restored {
        let input: String?
        let binding: SurfaceResumeBindingSnapshot?
    }

    private func restore(
        _ fixture: Fixture,
        mutate: (inout SessionTerminalPanelSnapshot) -> Void
    ) throws -> Restored {
        let source = Workspace(agentSessionAutoResumeDefaults: fixture.defaults)
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelID })
        var terminal = try #require(snapshot.panels[panelIndex].terminal)
        terminal.workingDirectory = fixture.workingDirectory.path
        mutate(&terminal)
        snapshot.panels[panelIndex].terminal = terminal

        let restored = Workspace(agentSessionAutoResumeDefaults: fixture.defaults)
        defer { restored.teardownAllPanels() }
        let restoredIDs = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restoredIDs[sourcePanelID])
        let panel = try #require(restored.terminalPanel(for: restoredPanelID))
        let restoredSnapshot = restored.sessionSnapshot(includeScrollback: false)
        let binding = restoredSnapshot.panels.first { $0.id == restoredPanelID }?.terminal?.resumeBinding
        return Restored(input: panel.surface.debugInitialInputForTesting(), binding: binding)
    }

    @Test("A claude attach pane restores as an attach with the binding's environment")
    func attachPaneRestoresAsAttach() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.registerSession(kind: "bg", sessionID: sessionID, jobID: jobID, processID: fixture.daemonProcessID)

        let restored = try restore(fixture) { terminal in
            terminal.agent = agent(fixture)
            terminal.resumeBinding = hookBinding(fixture, autoResume: false)
            terminal.wasAgentRunning = false
            terminal.claudeBackgroundViewer = viewer(fixture)
        }

        let input = try #require(restored.input)
        #expect(input.contains("'\(executable)' 'attach' '\(jobID)'"), Comment(rawValue: input))
        #expect(input.contains("'CLAUDE_CONFIG_DIR=\(fixture.configDirectory.path)'"), Comment(rawValue: input))
        #expect(input.contains("'ANTHROPIC_BASE_URL=http://127.0.0.1:31415'"), Comment(rawValue: input))
        #expect(input.contains("'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1'"), Comment(rawValue: input))
        #expect(!input.contains("--resume"), Comment(rawValue: input))
        #expect(!input.contains(" restore "), Comment(rawValue: input))
        // The manual binding stays for the daemon-gone case on a later relaunch.
        #expect(restored.binding?.checkpointId == sessionID)
        #expect(restored.binding?.autoResume == false)
    }

    @Test("A pane that spawned a background session and went back to shell work is not taken over")
    func idleSpawningPaneIsNotTakenOver() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.registerSession(kind: "bg", sessionID: sessionID, jobID: jobID, processID: fixture.daemonProcessID)

        let restored = try restore(fixture) { terminal in
            terminal.agent = agent(fixture)
            terminal.resumeBinding = hookBinding(fixture, autoResume: false)
            terminal.wasAgentRunning = false
        }

        #expect(restored.input == nil, Comment(rawValue: restored.input ?? ""))
        #expect(restored.binding?.checkpointId == sessionID)
    }

    @Test("A stale registry record on a reused PID does not block the resume fallback")
    func reusedPIDKeepsResumeFallback() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.registerSession(
            kind: "bg",
            sessionID: sessionID,
            jobID: jobID,
            processID: fixture.daemonProcessID,
            procStart: "Mon Jan  1 00:00:00 2001"
        )

        let restored = try restore(fixture) { terminal in
            terminal.agent = agent(fixture)
            terminal.resumeBinding = hookBinding(fixture, autoResume: true)
            terminal.wasAgentRunning = true
        }

        let input = try #require(restored.input)
        #expect(input.contains(" restore "), Comment(rawValue: input))
        #expect(!input.contains("'attach'"), Comment(rawValue: input))
    }

    @Test("Two panes on one background session: only the viewer pane attaches, neither resumes")
    func onePaneAttachesPerSession() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.registerSession(kind: "bg", sessionID: sessionID, jobID: jobID, processID: fixture.daemonProcessID)

        let source = Workspace(agentSessionAutoResumeDefaults: fixture.defaults)
        defer { source.teardownAllPanels() }
        let spawningPanelID = try #require(source.focusedPanelId)
        let paneID = try #require(source.bonsplitController.allPaneIds.first)
        let viewerPanelID = try #require(source.newTerminalSurface(inPane: paneID, focus: false)).id
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        for index in snapshot.panels.indices {
            guard var terminal = snapshot.panels[index].terminal else { continue }
            terminal.workingDirectory = fixture.workingDirectory.path
            terminal.agent = agent(fixture)
            terminal.resumeBinding = hookBinding(fixture, autoResume: true)
            terminal.wasAgentRunning = true
            if snapshot.panels[index].id == viewerPanelID {
                terminal.claudeBackgroundViewer = viewer(fixture)
            }
            snapshot.panels[index].terminal = terminal
        }
        // Put the viewer pane last so a first-come choice would pick the wrong pane.
        snapshot.panels = snapshot.panels.filter { $0.id != viewerPanelID }
            + snapshot.panels.filter { $0.id == viewerPanelID }

        let restored = Workspace(agentSessionAutoResumeDefaults: fixture.defaults)
        defer { restored.teardownAllPanels() }
        let restoredIDs = restored.restoreSessionSnapshot(snapshot)
        let viewerInput = try #require(
            restored.terminalPanel(for: try #require(restoredIDs[viewerPanelID]))?
                .surface.debugInitialInputForTesting()
        )
        let spawningInput = restored.terminalPanel(for: try #require(restoredIDs[spawningPanelID]))?
            .surface.debugInitialInputForTesting()

        #expect(viewerInput.contains("'attach' '\(jobID)'"), Comment(rawValue: viewerInput))
        #expect(spawningInput == nil, Comment(rawValue: spawningInput ?? ""))
    }

    /// A viewer pane's snapshot, as Close Tab saves it into closed-item history
    /// or a Dock transfer saves it for relaunch.
    private func viewerPanelSnapshot(_ fixture: Fixture, in workspace: Workspace) throws -> SessionPanelSnapshot {
        let panelID = try #require(workspace.focusedPanelId)
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        var panel = try #require(snapshot.panels.first { $0.id == panelID })
        var terminal = try #require(panel.terminal)
        terminal.workingDirectory = fixture.workingDirectory.path
        terminal.agent = agent(fixture)
        terminal.resumeBinding = hookBinding(fixture, autoResume: false)
        terminal.wasAgentRunning = false
        terminal.claudeBackgroundViewer = viewer(fixture)
        panel.terminal = terminal
        return panel
    }

    @Test("Reopening a closed claude attach pane reattaches the background session")
    func reopenedClosedPaneReattaches() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.registerSession(kind: "bg", sessionID: sessionID, jobID: jobID, processID: fixture.daemonProcessID)

        let workspace = Workspace(agentSessionAutoResumeDefaults: fixture.defaults)
        defer { workspace.teardownAllPanels() }
        let panel = try viewerPanelSnapshot(fixture, in: workspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let entry = ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: pane.id,
            tabIndex: 0,
            snapshot: panel
        )

        let reopenedID = try #require(workspace.restoreClosedPanel(entry))
        let input = try #require(workspace.terminalPanel(for: reopenedID)?.surface.debugInitialInputForTesting())
        #expect(input.contains("'\(executable)' 'attach' '\(jobID)'"), Comment(rawValue: input))
        #expect(input.contains("'CLAUDE_CONFIG_DIR=\(fixture.configDirectory.path)'"), Comment(rawValue: input))
        #expect(!input.contains("--resume"), Comment(rawValue: input))
    }

    @Test("A Dock panel restored through its workspace reattaches the background session")
    func dockRestoredPaneReattaches() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.registerSession(kind: "bg", sessionID: sessionID, jobID: jobID, processID: fixture.daemonProcessID)

        let workspace = Workspace(agentSessionAutoResumeDefaults: fixture.defaults)
        defer { workspace.teardownAllPanels() }
        let panel = try viewerPanelSnapshot(fixture, in: workspace)

        let detached = try #require(workspace.detachedSurfaceForDockSessionRestore(
            panel,
            snapshotWorkspaceId: workspace.id,
            excludingStableIdentities: [],
            restorableAgentIndex: nil
        ))
        let terminal = try #require(detached.panel as? TerminalPanel)
        defer { terminal.close() }
        let input = try #require(terminal.surface.debugInitialInputForTesting())
        #expect(input.contains("'\(executable)' 'attach' '\(jobID)'"), Comment(rawValue: input))
        #expect(!input.contains("--resume"), Comment(rawValue: input))
    }

    @Test("A running background session never resumes as a second writer")
    func runningBackgroundSessionNeverResumes() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.registerSession(kind: "bg", sessionID: sessionID, jobID: jobID, processID: fixture.daemonProcessID)

        let restored = try restore(fixture) { terminal in
            terminal.agent = agent(fixture)
            terminal.resumeBinding = hookBinding(fixture, autoResume: true)
            terminal.wasAgentRunning = true
        }

        let input = try #require(restored.input)
        #expect(input.contains("'attach' '\(jobID)'"), Comment(rawValue: input))
        #expect(!input.contains(" restore "), Comment(rawValue: input))
        #expect(!input.contains("--resume"), Comment(rawValue: input))
    }

    @Test("An interactive Claude pane still resumes through the restore verb")
    func interactiveClaudePaneStillResumes() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        // Claude's registry lists the same session, but as an interactive one.
        try fixture.registerSession(kind: "interactive", sessionID: sessionID, jobID: nil, processID: fixture.daemonProcessID)

        let restored = try restore(fixture) { terminal in
            terminal.agent = agent(fixture)
            terminal.resumeBinding = hookBinding(fixture, autoResume: true)
            terminal.wasAgentRunning = true
        }

        let input = try #require(restored.input)
        #expect(input.contains(" restore "), Comment(rawValue: input))
        #expect(!input.contains("'attach'"), Comment(rawValue: input))
    }

    @Test("When the daemon no longer hosts the session the pane keeps its manual resume binding")
    func daemonGoneFallsBackToManualResume() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let stoppedProcessID = fixture.daemonProcessID
        try fixture.registerSession(kind: "bg", sessionID: sessionID, jobID: jobID, processID: stoppedProcessID)
        fixture.daemonProcess.terminate()
        fixture.daemonProcess.waitUntilExit()

        let restored = try restore(fixture) { terminal in
            terminal.agent = agent(fixture)
            terminal.resumeBinding = hookBinding(fixture, autoResume: false)
            terminal.wasAgentRunning = false
            terminal.claudeBackgroundViewer = viewer(fixture)
        }

        #expect(restored.input == nil, Comment(rawValue: restored.input ?? ""))
        #expect(restored.binding?.checkpointId == sessionID)
        #expect(restored.binding?.autoResume == false)
    }
}
