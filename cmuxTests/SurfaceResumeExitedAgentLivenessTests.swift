import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SurfaceResumeExitedAgentLivenessTests {
    @Test("Exited hook process does not auto-resume from an unknown shell state")
    @MainActor
    func exitedHookProcessDoesNotAutoResumeFromUnknownShellState() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-exited-agent-resume-\(UUID().uuidString)", isDirectory: true)
        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let previousHookStateDirectory = getenv("CMUX_AGENT_HOOK_STATE_DIR").map { String(cString: $0) }
        setenv("CMUX_AGENT_HOOK_STATE_DIR", hookStateDirectory.path, 1)
        defer {
            if let previousHookStateDirectory {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDirectory, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
            try? fileManager.removeItem(at: root)
        }

        let defaultsName = "cmux-exited-agent-resume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        let panelID = try #require(source.focusedPanelId)
        let sessionID = "codex-exited-agent-session"
        try writeCodexHookRecord(
            sessionID: sessionID,
            workspaceID: source.id,
            panelID: panelID,
            root: root,
            fileManager: fileManager
        )

        let agentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil },
            processPresenceProvider: { _ in .absent }
        )
        #expect(agentIndex.snapshot(workspaceId: source.id, panelId: panelID)?.sessionId == sessionID)
        #expect(!agentIndex.hasLiveProcess(workspaceId: source.id, panelId: panelID))

        let bindingIndex = codexBindingIndex(
            sessionID: sessionID,
            workspaceID: source.id,
            panelID: panelID,
            updatedAt: 1_777_777_778
        )
        source.updatePanelShellActivityState(panelId: panelID, state: .unknown)
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: agentIndex,
            surfaceResumeBindingIndex: bindingIndex
        )

        #expect(snapshot.panels.first?.terminal?.wasAgentRunning == false)

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restored.focusedPanelId)
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(restoredPanel.surface.debugInitialCommand() == nil)
        #expect(!restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
        #expect(
            restored.sessionSnapshot(includeScrollback: false)
                .panels.first?.terminal?.agent?.sessionId == sessionID
        )
    }

    @Test("Newer agent binding and shell activity do not override cached exited process")
    @MainActor
    func newerAgentBindingAndShellActivityDoNotOverrideCachedExitedProcess() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-newer-agent-binding-resume-\(UUID().uuidString)", isDirectory: true)
        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let previousHookStateDirectory = getenv("CMUX_AGENT_HOOK_STATE_DIR").map { String(cString: $0) }
        setenv("CMUX_AGENT_HOOK_STATE_DIR", hookStateDirectory.path, 1)
        defer {
            if let previousHookStateDirectory {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDirectory, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
            try? fileManager.removeItem(at: root)
        }

        let defaultsName = "cmux-newer-agent-binding-resume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        let panelID = try #require(source.focusedPanelId)
        let sessionID = "codex-newer-agent-binding-session"
        try writeCodexHookRecord(
            sessionID: sessionID,
            workspaceID: source.id,
            panelID: panelID,
            root: root,
            fileManager: fileManager
        )

        let exitedIndex = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil },
            processPresenceProvider: { _ in .absent }
        )
        let observation = try #require(exitedIndex.entry(workspaceId: source.id, panelId: panelID))
        #expect(observation.processLiveness == .exited)

        let newerBindingIndex = codexBindingIndex(
            sessionID: sessionID,
            workspaceID: source.id,
            panelID: panelID,
            updatedAt: observation.updatedAt + 1
        )
        source.updatePanelShellActivityState(panelId: panelID, state: .commandRunning)
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: exitedIndex,
            surfaceResumeBindingIndex: newerBindingIndex
        )
        #expect(snapshot.panels.first?.terminal?.wasAgentRunning == false)

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restored.focusedPanelId)
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(restoredPanel.surface.debugInitialCommand() == nil)
        #expect(!restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
    }

    @Test("Exact live runtime PID overrides cached exited process")
    @MainActor
    func exactLiveRuntimePIDOverridesCachedExitedProcess() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-live-runtime-agent-resume-\(UUID().uuidString)", isDirectory: true)
        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let previousHookStateDirectory = getenv("CMUX_AGENT_HOOK_STATE_DIR").map { String(cString: $0) }
        setenv("CMUX_AGENT_HOOK_STATE_DIR", hookStateDirectory.path, 1)
        defer {
            if let previousHookStateDirectory {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDirectory, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
            try? fileManager.removeItem(at: root)
        }

        let defaultsName = "cmux-live-runtime-agent-resume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        let panelID = try #require(source.focusedPanelId)
        let sessionID = "codex-live-runtime-agent-session"
        try writeCodexHookRecord(
            sessionID: sessionID,
            workspaceID: source.id,
            panelID: panelID,
            root: root,
            fileManager: fileManager
        )

        let exitedIndex = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil },
            processPresenceProvider: { _ in .absent }
        )
        let observation = try #require(exitedIndex.entry(workspaceId: source.id, panelId: panelID))
        #expect(observation.processLiveness == .exited)

        let livePID = getpid()
        let liveIdentity = try #require(Workspace.agentPIDProcessIdentity(pid: livePID))
        let currentProcessIdentity: (Int) -> AgentPIDProcessIdentity? = {
            $0 == Int(livePID) ? liveIdentity : nil
        }
        source.recordAgentPID(
            key: "codex.wrong-session",
            pid: livePID,
            panelId: panelID,
            refreshPorts: false
        )
        #expect(
            source.confirmedRuntimeAgentProcessIdentities(
                for: observation.snapshot,
                panelId: panelID,
                currentProcessIdentity: currentProcessIdentity
            ).isEmpty
        )

        source.recordAgentPID(
            key: "codex.\(sessionID)",
            pid: livePID,
            panelId: panelID,
            refreshPorts: false
        )
        #expect(
            source.confirmedRuntimeAgentProcessIdentities(
                for: observation.snapshot,
                panelId: panelID,
                currentProcessIdentity: currentProcessIdentity
            ) == [liveIdentity]
        )

        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: exitedIndex,
            surfaceResumeBindingIndex: codexBindingIndex(
                sessionID: sessionID,
                workspaceID: source.id,
                panelID: panelID
            ),
            currentAgentProcessIdentity: currentProcessIdentity
        )
        #expect(snapshot.panels.first?.terminal?.wasAgentRunning == true)

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restored.focusedPanelId)
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(restoredPanel.surface.debugInitialCommand() != nil)
    }

    @Test("Cached running process is revalidated before surface resume")
    @MainActor
    func cachedRunningProcessIsRevalidatedBeforeSurfaceResume() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cached-running-agent-resume-\(UUID().uuidString)", isDirectory: true)
        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let previousHookStateDirectory = getenv("CMUX_AGENT_HOOK_STATE_DIR").map { String(cString: $0) }
        setenv("CMUX_AGENT_HOOK_STATE_DIR", hookStateDirectory.path, 1)
        defer {
            if let previousHookStateDirectory {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDirectory, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
            try? fileManager.removeItem(at: root)
        }

        let defaultsName = "cmux-cached-running-agent-resume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        let panelID = try #require(source.focusedPanelId)
        let sessionID = "codex-cached-running-agent-session"
        let recordedIdentity = AgentPIDProcessIdentity(
            pid: 987_654_321,
            startSeconds: 1_777_777_700,
            startMicroseconds: 0
        )
        try writeCodexHookRecord(
            sessionID: sessionID,
            workspaceID: source.id,
            panelID: panelID,
            root: root,
            fileManager: fileManager
        )

        let agentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { processID in
                processID == Int(recordedIdentity.pid)
                    ? self.codexProcessArguments(workspaceID: source.id, panelID: panelID)
                    : nil
            },
            processPresenceProvider: { _ in .present },
            processIdentityProvider: { processID in
                processID == Int(recordedIdentity.pid) ? recordedIdentity : nil
            }
        )
        let observation = try #require(agentIndex.entry(workspaceId: source.id, panelId: panelID))
        #expect(observation.processLiveness == .running)
        #expect(observation.agentProcessIdentities == [Int(recordedIdentity.pid): recordedIdentity])

        source.updatePanelShellActivityState(panelId: panelID, state: .promptIdle)
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: agentIndex,
            surfaceResumeBindingIndex: codexBindingIndex(
                sessionID: sessionID,
                workspaceID: source.id,
                panelID: panelID
            ),
            currentAgentProcessIdentity: { _ in nil },
            agentProcessPresence: { _ in .absent }
        )

        #expect(snapshot.panels.first?.terminal?.wasAgentRunning == false)

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restored.focusedPanelId)
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(restoredPanel.surface.debugInitialCommand() == nil)
        #expect(!restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
    }

    @Test("Autosave fingerprint includes agent process liveness")
    @MainActor
    func autosaveFingerprintIncludesAgentProcessLiveness() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-agent-liveness-fingerprint-\(UUID().uuidString)", isDirectory: true)
        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let previousHookStateDirectory = getenv("CMUX_AGENT_HOOK_STATE_DIR").map { String(cString: $0) }
        setenv("CMUX_AGENT_HOOK_STATE_DIR", hookStateDirectory.path, 1)
        defer {
            if let previousHookStateDirectory {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDirectory, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
            try? fileManager.removeItem(at: root)
        }

        let manager = TabManager()
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let sessionID = "codex-agent-liveness-fingerprint"
        let recordedIdentity = AgentPIDProcessIdentity(
            pid: 987_654_321,
            startSeconds: 1_777_777_700,
            startMicroseconds: 0
        )
        try writeCodexHookRecord(
            sessionID: sessionID,
            workspaceID: workspace.id,
            panelID: panelID,
            root: root,
            fileManager: fileManager
        )

        let runningIndex = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { processID in
                processID == Int(recordedIdentity.pid)
                    ? self.codexProcessArguments(workspaceID: workspace.id, panelID: panelID)
                    : nil
            },
            processPresenceProvider: { _ in .present },
            processIdentityProvider: { _ in recordedIdentity }
        )
        let exitedIndex = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil },
            processPresenceProvider: { _ in .absent }
        )

        #expect(runningIndex.entry(workspaceId: workspace.id, panelId: panelID)?.processLiveness == .running)
        #expect(exitedIndex.entry(workspaceId: workspace.id, panelId: panelID)?.processLiveness == .exited)
        #expect(
            manager.sessionAutosaveFingerprint(restorableAgentIndex: runningIndex) !=
                manager.sessionAutosaveFingerprint(restorableAgentIndex: exitedIndex)
        )
    }

    private func codexBindingIndex(
        sessionID: String,
        workspaceID: UUID,
        panelID: UUID,
        updatedAt: TimeInterval = 1_777_777_777
    ) -> SurfaceResumeBindingIndex {
        SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: workspaceID, panelId: panelID):
                SurfaceResumeBindingSnapshot(
                    name: "Codex",
                    kind: "codex",
                    command: "codex resume \(sessionID)",
                    cwd: "/tmp/repo",
                    checkpointId: sessionID,
                    source: "agent-hook",
                    autoResume: true,
                    updatedAt: updatedAt
                ),
        ])
    }

    private func codexProcessArguments(
        workspaceID: UUID,
        panelID: UUID
    ) -> CmuxTopProcessArguments {
        CmuxTopProcessArguments(
            arguments: ["/usr/local/bin/codex"],
            environment: [
                "CMUX_AGENT_LAUNCH_KIND": "codex",
                "CMUX_WORKSPACE_ID": workspaceID.uuidString,
                "CMUX_SURFACE_ID": panelID.uuidString,
            ]
        )
    }

    private func writeCodexHookRecord(
        sessionID: String,
        workspaceID: UUID,
        panelID: UUID,
        root: URL,
        fileManager: FileManager
    ) throws {
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: root.path)
        try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": workspaceID.uuidString,
            "surfaceId": panelID.uuidString,
            "cwd": "/tmp/repo",
            "pid": 987_654_321,
            "isRestorable": true,
            "updatedAt": 1_777_777_777,
            "launchCommand": [
                "launcher": "codex",
                "executablePath": "/usr/local/bin/codex",
                "arguments": ["/usr/local/bin/codex"],
                "workingDirectory": "/tmp/repo",
                "capturedAt": 1_777_777_777,
                "source": "test",
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": [sessionID: record],
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: storeURL, options: .atomic)
    }
}
