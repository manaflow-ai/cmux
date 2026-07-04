import CMUXAgentLaunch
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Session restore snapshot repair", .serialized)
struct SessionRestoreSnapshotRepairTests {
    private func sessionStore() -> SessionSnapshotRepository<AppSessionSnapshot> {
        SessionSnapshotRepository(
            schemaVersion: SessionSnapshotSchema.currentVersion,
            bundleIdentifier: "com.cmuxterm.tests",
            repairLoadedSnapshot: AppSessionSnapshot.repairLoadedSessionSnapshot
        )
    }

    @MainActor
    @Test("Load repair drops poisoned shell resume binding and persists cleanup")
    func loadRepairDropsPoisonedShellResumeBindingAndPersistsCleanup() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = sessionStore()
        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let source = Workspace()
        let sourcePanelId = try #require(source.focusedPanelId)
        let sessionId = "codex-load-repair-session"
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "{ cd -- '/tmp/right' 2>/dev/null || [ ! -d '/tmp/right' ]; } && 'bash' 'resume' '\(sessionId)'",
                cwd: "/tmp/right",
                checkpointId: sessionId,
                source: "agent-hook",
                autoResume: true,
                updatedAt: 10
            ),
        ])
        let workspaceSnapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )
        let appSnapshot = makeSnapshot(workspaceSnapshot: workspaceSnapshot)
        #expect(store.save(appSnapshot, fileURL: snapshotURL))

        let loaded = try #require(store.load(fileURL: snapshotURL))
        let loadedBinding = loaded.windows.first?.tabManager.workspaces.first?.panels.first?.terminal?.resumeBinding
        #expect(loadedBinding == nil)

        let persistedData = try Data(contentsOf: snapshotURL)
        let persisted = try JSONDecoder().decode(AppSessionSnapshot.self, from: persistedData)
        let persistedBinding = persisted.windows.first?.tabManager.workspaces.first?.panels.first?.terminal?.resumeBinding
        #expect(persistedBinding == nil)
    }

    @MainActor
    @Test("Load repair keeps custom shell-named agent hook binding")
    func loadRepairKeepsCustomShellNamedAgentHookBinding() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = sessionStore()
        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let source = Workspace()
        let sourcePanelId = try #require(source.focusedPanelId)
        let command = "{ cd -- '/tmp/right' 2>/dev/null || [ ! -d '/tmp/right' ]; } && 'fish' 'resume' 'custom-session'"
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Fish Agent",
                kind: "fish",
                command: command,
                cwd: "/tmp/right",
                checkpointId: "custom-session",
                source: "agent-hook",
                autoResume: true,
                updatedAt: 10
            ),
        ])
        let workspaceSnapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )
        let appSnapshot = makeSnapshot(workspaceSnapshot: workspaceSnapshot)
        #expect(store.save(appSnapshot, fileURL: snapshotURL))

        let loaded = try #require(store.load(fileURL: snapshotURL))
        let loadedBinding = loaded.windows.first?.tabManager.workspaces.first?.panels.first?.terminal?.resumeBinding
        #expect(loadedBinding?.command == command)
    }

    @Test("Registry-owned built-in shell resume bindings are treated as poisoned")
    func registryOwnedBuiltInShellResumeBindingIsPoisoned() {
        let binding = SurfaceResumeBindingSnapshot(
            name: "Grok",
            kind: "grok",
            command: "{ cd -- '/tmp/right' 2>/dev/null || [ ! -d '/tmp/right' ]; } && 'bash' 'resume' 'grok-session'",
            cwd: "/tmp/right",
            checkpointId: "grok-session",
            source: "agent-hook",
            autoResume: true,
            updatedAt: 10
        )

        #expect(binding.trustedForSessionRestore == nil)
    }

    @MainActor
    @Test("Load repair drops wrong-fork launch capture and recovers cwd")
    func loadRepairDropsWrongForkLaunchCaptureAndRecoversCWD() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = sessionStore()
        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let source = Workspace()
        let sourcePanelId = try #require(source.focusedPanelId)
        source.updatePanelDirectory(panelId: sourcePanelId, directory: "/tmp/right")
        var workspaceSnapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(workspaceSnapshot.panels.firstIndex { $0.id == sourcePanelId })
        var panel = workspaceSnapshot.panels[panelIndex]
        var terminal = try #require(panel.terminal)
        terminal.workingDirectory = "/tmp/right"
        terminal.agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-load-repair-session",
            workingDirectory: "/tmp/wrong",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude", "--resume", "claude-session"],
                workingDirectory: "/tmp/wrong",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
        panel.directory = "/tmp/right"
        panel.terminal = terminal
        workspaceSnapshot.panels[panelIndex] = panel
        let appSnapshot = makeSnapshot(workspaceSnapshot: workspaceSnapshot)
        #expect(store.save(appSnapshot, fileURL: snapshotURL))

        let loaded = try #require(store.load(fileURL: snapshotURL))
        let loadedAgent = try #require(
            loaded.windows.first?.tabManager.workspaces.first?.panels.first?.terminal?.agent
        )
        #expect(loadedAgent.launchCommand == nil)
        #expect(loadedAgent.workingDirectory == "/tmp/right")
        #expect(
            loadedAgent.resumeCommand
                == "{ cd -- '/tmp/right' 2>/dev/null || [ ! -d '/tmp/right' ]; } && 'codex' 'resume' 'codex-load-repair-session'"
        )
    }

    @Test("Resume command drops missing-launcher wrong-fork launch capture")
    func resumeCommandDropsMissingLauncherWrongForkLaunchCapture() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-session-123",
            workingDirectory: "/tmp/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: nil,
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude", "--resume", "claude-session"],
                workingDirectory: "/tmp/wrong",
                environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude"],
                capturedAt: 123,
                source: "process"
            )
        )

        #expect(
            snapshot.resumeCommand
                == "{ cd -- '/tmp/repo' 2>/dev/null || [ ! -d '/tmp/repo' ]; } && 'codex' 'resume' 'codex-session-123'"
        )
    }

    @Test("Resume command preserves missing-launcher Hermes launch capture")
    func resumeCommandPreservesMissingLauncherHermesLaunchCapture() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .hermesAgent,
            sessionId: "hermes-session-123",
            workingDirectory: "/tmp/hermes repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: nil,
                executablePath: "/opt/homebrew/bin/hermes",
                arguments: [
                    "/opt/homebrew/bin/hermes",
                    "--provider",
                    "custom",
                    "--model",
                    "gpt-5.5"
                ],
                workingDirectory: "/tmp/hermes repo",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        #expect(
            snapshot.resumeCommand
                == "{ cd -- '/tmp/hermes repo' 2>/dev/null || [ ! -d '/tmp/hermes repo' ]; } && '/opt/homebrew/bin/hermes' '--provider' 'custom' '--model' 'gpt-5.5' '--resume' 'hermes-session-123'"
        )
    }

    @Test("Resume command preserves missing-launcher RovoDev acli launch capture")
    func resumeCommandPreservesMissingLauncherRovoDevAcliLaunchCapture() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .rovodev,
            sessionId: "rovo-session-123",
            workingDirectory: "/tmp/rovo repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: nil,
                executablePath: "/usr/local/bin/acli",
                arguments: ["/usr/local/bin/acli", "rovodev", "run"],
                workingDirectory: "/tmp/rovo repo",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        #expect(
            snapshot.resumeCommand
                == "{ cd -- '/tmp/rovo repo' 2>/dev/null || [ ! -d '/tmp/rovo repo' ]; } && '/usr/local/bin/acli' 'rovodev' 'run' '--restore' 'rovo-session-123'"
        )
    }

    private func makeSnapshot(workspaceSnapshot: SessionWorkspaceSnapshot) -> AppSessionSnapshot {
        let window = SessionWindowSnapshot(
            frame: SessionRectSnapshot(x: 10, y: 20, width: 900, height: 700),
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [workspaceSnapshot]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: [window]
        )
    }
}
