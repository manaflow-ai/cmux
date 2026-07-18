import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @MainActor
    @Test func restoredHibernationAdoptsCurrentRuntimeAndPanelBindingBeforeAgentQueries() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-hibernation-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let sessionID = "restored-hibernation"
        let runtimeID = "restored-runtime"
        let environmentOverrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": runtimeID,
            "CMUX_SOCKET_PATH": "/tmp/cmux-restored-runtime.sock",
            "CMUX_BUNDLE_ID": "com.cmuxterm.restored-runtime",
        ]
        let previousEnvironment = environmentOverrides.keys.map {
            ($0, ProcessInfo.processInfo.environment[$0])
        }
        for (key, value) in environmentOverrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let source = Workspace()
        let sourcePanelID = try #require(source.focusedPanelId)
        let sourcePanel = try #require(source.terminalPanel(for: sourcePanelID))
        let sourcePaneID = try #require(source.paneId(forPanelId: sourcePanelID))
        _ = try #require(source.newTerminalSurface(inPane: sourcePaneID, focus: true))
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex"],
                workingDirectory: root.path,
                environment: nil,
                capturedAt: 90,
                source: "agent-hook"
            )
        )
        #expect(sourcePanel.enterAgentHibernation(
            agent: agent,
            lastActivityAt: Date(timeIntervalSince1970: 90),
            hibernatedAt: Date(timeIntervalSince1970: 100)
        ))

        let oldRuntime: [String: Any] = ["id": "previous-runtime"]
        let activeSlot: [String: Any] = ["sessionId": sessionID, "updatedAt": 100.0]
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionID: [
                "sessionId": sessionID,
                "workspaceId": source.id.uuidString,
                "surfaceId": sourcePanelID.uuidString,
                "runId": "run",
                "activeRunId": "run",
                "restoreAuthority": true,
                "foregroundState": "completed",
                "sessionState": "hibernated",
                "cmuxRuntime": oldRuntime,
                "runs": [[
                    "runId": "run",
                    "restoreAuthority": true,
                    "cmuxRuntime": oldRuntime,
                    "startedAt": 90.0,
                    "updatedAt": 100.0,
                ]],
                "startedAt": 90.0,
                "updatedAt": 100.0,
            ]],
            "activeSessionsByWorkspace": [source.id.uuidString: activeSlot],
            "activeSessionsBySurface": [sourcePanelID.uuidString: activeSlot],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": ["unrelated-claude": [
                "sessionId": "unrelated-claude",
                "workspaceId": UUID().uuidString,
                "surfaceId": UUID().uuidString,
                "sessionState": "hibernated",
                "restoreAuthority": true,
                "startedAt": 90.0,
                "updatedAt": 100.0,
            ]],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("claude-hook-sessions.json"),
            options: .atomic
        )
        let registry = CmuxAgentSessionRegistry(url: registryURL)

        let sourceSnapshot = source.sessionSnapshot(includeScrollback: false)
        let selectedShellWorkspace = Workspace()
        let selectedShellSnapshot = selectedShellWorkspace.sessionSnapshot(includeScrollback: false)
        let restoredWindowID = UUID()
        let appDelegate = try #require(AppDelegate.shared)
        defer {
            _ = appDelegate.closeMainWindow(windowId: restoredWindowID, recordHistory: false)
        }
        let appSnapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 100,
            windows: [SessionWindowSnapshot(
                windowId: restoredWindowID,
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(
                    selectedWorkspaceIndex: 0,
                    workspaces: [selectedShellSnapshot, sourceSnapshot]
                ),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )]
        )
        #expect(appDelegate.restorePreviousSessionSnapshot(appSnapshot, shouldActivate: false))
        let restoredManager = try #require(appDelegate.tabManagerFor(windowId: restoredWindowID))
        let restored = try #require(restoredManager.tabs.first { workspace in
            workspace.sessionSnapshot(includeScrollback: false).panels.contains {
                $0.terminal?.agent?.sessionId == sessionID
            }
        })
        let restoredPanelSnapshot = try #require(
            restored.sessionSnapshot(includeScrollback: false).panels.first {
                $0.terminal?.agent?.sessionId == sessionID
            }
        )
        let restoredPanelID = restoredPanelSnapshot.id
        #expect(restored.id != source.id)
        #expect(restoredPanelID != sourcePanelID)
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        #expect(restoredPanel.isAgentHibernated)

        let snapshot = try registry.snapshot(provider: "codex")
        let unrelatedProviderSnapshot = try registry.snapshot(provider: "claude")
        #expect(unrelatedProviderSnapshot.records.isEmpty)
        let record = try #require(snapshot.records.first(where: { $0.sessionID == sessionID }))
        let recordObject = try #require(
            JSONSerialization.jsonObject(with: record.json) as? [String: Any]
        )
        #expect(recordObject["sessionState"] as? String == "hibernated")
        let runs = try #require(recordObject["runs"] as? [[String: Any]])
        #expect((runs.first?["cmuxRuntime"] as? [String: Any])?["id"] as? String == runtimeID)
        let sessionSlots = snapshot.activeSlots.filter { $0.sessionID == sessionID }
        #expect(Set(sessionSlots.map { $0.scopeID }) == [restored.id.uuidString, restoredPanelID.uuidString])
        #expect(Set(sessionSlots.map { $0.scope.rawValue }) == ["workspace", "surface"])

        var cliEnvironment = ProcessInfo.processInfo.environment
        for key in Array(cliEnvironment.keys) where key.hasPrefix("CMUX_") {
            cliEnvironment.removeValue(forKey: key)
        }
        cliEnvironment.merge(environmentOverrides) { _, new in new }
        cliEnvironment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        cliEnvironment["HOME"] = root.path
        for command in [["agents", "list", "--json"], ["agents", "tree", "--json"]] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: command,
                environment: cliEnvironment,
                timeout: 5
            )
            #expect(!result.timedOut, Comment(rawValue: result.stdout))
            #expect(result.status == 0, Comment(rawValue: result.stdout))
            let output = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let rows = (output["sessions"] as? [[String: Any]]) ?? (output["nodes"] as? [[String: Any]])
            let restoredRow = try #require(rows?.first { $0["session_id"] as? String == sessionID })
            #expect(restoredRow["workspace_id"] as? String == restored.id.uuidString)
            #expect(restoredRow["surface_id"] as? String == restoredPanelID.uuidString)
            #expect(restoredRow["session_state"] as? String == "hibernated")
        }
    }

    @MainActor
    @Test func legacyOnlyRestoredHibernationImportsAtSharedAdoptionBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-hibernation-legacy-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let environmentOverrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "legacy-only-runtime",
        ]
        let previousEnvironment = environmentOverrides.keys.map {
            ($0, ProcessInfo.processInfo.environment[$0])
        }
        for (key, value) in environmentOverrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(
            root: root,
            sessionID: "legacy-only-session"
        )
        let activeSlot: [String: Any] = [
            "sessionId": fixture.agent.sessionId,
            "updatedAt": 20.0,
        ]
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [fixture.agent.sessionId: [
                "sessionId": fixture.agent.sessionId,
                "workspaceId": fixture.source.id.uuidString,
                "surfaceId": fixture.sourcePanelID.uuidString,
                "sessionState": "hibernated",
                "restoreAuthority": true,
                "startedAt": 10.0,
                "updatedAt": 20.0,
            ]],
            "activeSessionsByWorkspace": [fixture.source.id.uuidString: activeSlot],
            "activeSessionsBySurface": [fixture.sourcePanelID.uuidString: activeSlot],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"),
            options: .atomic
        )
        #expect(!FileManager.default.fileExists(atPath: registryURL.path))

        let restored = Workspace()
        let mapping = restored.restoreSessionSnapshot(fixture.snapshot)
        let restoredPanelID = try #require(mapping[fixture.sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(restoredPanel.isAgentHibernated)
        #expect(restored.restoredAgentSnapshotForTesting(panelId: restoredPanelID)?.sessionId == fixture.agent.sessionId)
        let registrySnapshot = try CmuxAgentSessionRegistry(url: registryURL).snapshot(provider: "codex")
        let record = try #require(registrySnapshot.records.first)
        let object = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])
        #expect(object["workspaceId"] as? String == restored.id.uuidString)
        #expect(object["surfaceId"] as? String == restoredPanelID.uuidString)
        #expect(object["sessionState"] as? String == "hibernated")
        #expect(Set(registrySnapshot.activeSlots.map(\.scopeID)) == [
            restored.id.uuidString,
            restoredPanelID.uuidString,
        ])
    }

    @MainActor
    @Test func restoredHibernationWithoutStartupRegistryFallsBackToPlainShell() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-hibernation-missing-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let environmentOverrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "missing-registry-runtime",
        ]
        let previousEnvironment = environmentOverrides.keys.map {
            ($0, ProcessInfo.processInfo.environment[$0])
        }
        for (key, value) in environmentOverrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(
            root: root,
            sessionID: "missing-registry-session"
        )
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [fixture.agent.sessionId: [
                "sessionId": fixture.agent.sessionId,
                "workspaceId": fixture.source.id.uuidString,
                "surfaceId": fixture.sourcePanelID.uuidString,
                "restoreAuthority": true,
                "startedAt": 10.0,
                "updatedAt": 20.0,
            ]],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)

        let restored = Workspace()
        let mapping = restored.restoreSessionSnapshot(fixture.snapshot)
        let restoredPanelID = try #require(mapping[fixture.sourcePanelID])
        let panel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(!panel.isAgentHibernated)
        #expect(restored.restoredAgentSnapshotForTesting(panelId: restoredPanelID) == nil)
        #expect(!panel.surface.debugInitialInputMetadata().hasInitialInput)
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 0)
        let createAttempts = panel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting()
        #expect(createAttempts <= 1)
        #expect(panel.surface.debugBackgroundSurfaceStartQueuedForTesting() || createAttempts == 1)
        let restoredPanelSnapshot = try #require(
            restored.sessionSnapshot(includeScrollback: false).panels.first { $0.id == restoredPanelID }
        )
        #expect(restoredPanelSnapshot.terminal?.agent == nil)
        #expect(restoredPanelSnapshot.terminal?.hibernation == nil)
        #expect(restoredPanelSnapshot.terminal?.resumeBinding == nil)
        let registrySnapshot = try CmuxAgentSessionRegistry(url: registryURL).snapshot(provider: "codex")
        #expect(registrySnapshot.records.isEmpty)
    }

    @MainActor
    @Test func restoredHibernationCannotStealANewerLiveBinding() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-hibernation-newer-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let runtimeID = "newer-owner-runtime"
        let environmentOverrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": runtimeID,
        ]
        let previousEnvironment = environmentOverrides.keys.map {
            ($0, ProcessInfo.processInfo.environment[$0])
        }
        for (key, value) in environmentOverrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(
            root: root,
            sessionID: "newer-owner-session"
        )
        let newerWorkspaceID = UUID().uuidString
        let newerSurfaceID = UUID().uuidString
        let updatedAt = Date().timeIntervalSince1970 - 10
        let runtime: [String: Any] = ["id": runtimeID]
        let recordObject: [String: Any] = [
            "sessionId": fixture.agent.sessionId,
            "workspaceId": newerWorkspaceID,
            "surfaceId": newerSurfaceID,
            "activeRunId": "newer-run",
            "restoreAuthority": true,
            "sessionState": "active",
            "cmuxRuntime": runtime,
            "runs": [[
                "runId": "newer-run",
                "restoreAuthority": true,
                "cmuxRuntime": runtime,
                "startedAt": updatedAt - 10,
                "updatedAt": updatedAt,
            ]],
            "startedAt": updatedAt - 10,
            "updatedAt": updatedAt,
        ]
        let slotJSON = try JSONSerialization.data(withJSONObject: [
            "sessionId": fixture.agent.sessionId,
            "updatedAt": updatedAt,
        ], options: [.sortedKeys])
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        try registry.apply(
            provider: "codex",
            records: [CmuxAgentSessionRegistry.Record(
                provider: "codex",
                sessionID: fixture.agent.sessionId,
                updatedAt: updatedAt,
                json: try JSONSerialization.data(withJSONObject: recordObject, options: [.sortedKeys])
            )],
            activeSlots: [
                CmuxAgentSessionRegistry.ActiveSlot(
                    provider: "codex",
                    scope: .workspace,
                    scopeID: newerWorkspaceID,
                    sessionID: fixture.agent.sessionId,
                    updatedAt: updatedAt,
                    json: slotJSON
                ),
                CmuxAgentSessionRegistry.ActiveSlot(
                    provider: "codex",
                    scope: .surface,
                    scopeID: newerSurfaceID,
                    sessionID: fixture.agent.sessionId,
                    updatedAt: updatedAt,
                    json: slotJSON
                ),
            ]
        )

        let restored = Workspace()
        let mapping = restored.restoreSessionSnapshot(fixture.snapshot)
        let restoredPanelID = try #require(mapping[fixture.sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        #expect(!restoredPanel.isAgentHibernated)
        #expect(restored.restoredAgentSnapshotForTesting(panelId: restoredPanelID) == nil)
        #expect(!restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)

        let snapshot = try registry.snapshot(provider: "codex")
        let stored = try #require(snapshot.records.first)
        let storedObject = try #require(JSONSerialization.jsonObject(with: stored.json) as? [String: Any])
        #expect(storedObject["workspaceId"] as? String == newerWorkspaceID)
        #expect(storedObject["surfaceId"] as? String == newerSurfaceID)
        #expect(storedObject["sessionState"] as? String == "active")
        #expect(Set(snapshot.activeSlots.map(\.scopeID)) == [newerWorkspaceID, newerSurfaceID])
        #expect(!snapshot.activeSlots.contains { $0.scopeID == restoredPanelID.uuidString })

        var cliEnvironment = ProcessInfo.processInfo.environment
        for key in Array(cliEnvironment.keys) where key.hasPrefix("CMUX_") {
            cliEnvironment.removeValue(forKey: key)
        }
        cliEnvironment.merge(environmentOverrides) { _, new in new }
        cliEnvironment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        cliEnvironment["HOME"] = root.path
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--json"],
            environment: cliEnvironment,
            timeout: 5
        )
        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let output = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let rows = try #require(output["sessions"] as? [[String: Any]])
        let row = try #require(rows.first { $0["session_id"] as? String == fixture.agent.sessionId })
        #expect(row["workspace_id"] as? String == newerWorkspaceID)
        #expect(row["surface_id"] as? String == newerSurfaceID)
    }

    @MainActor
    @Test(arguments: ["active", "restoring"])
    func restoredHibernationCannotStealSameBindingFromLiveLifecycle(_ lifecycle: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-restored-hibernation-same-binding-\(lifecycle)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let environmentOverrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "restore-attempt-runtime",
        ]
        let previousEnvironment = environmentOverrides.keys.map {
            ($0, ProcessInfo.processInfo.environment[$0])
        }
        for (key, value) in environmentOverrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(
            root: root,
            sessionID: "same-binding-\(lifecycle)-session"
        )
        let updatedAt = 30.0
        let runtime: [String: Any] = ["id": "live-owner-runtime"]
        let recordObject: [String: Any] = [
            "sessionId": fixture.agent.sessionId,
            "workspaceId": fixture.source.id.uuidString,
            "surfaceId": fixture.sourcePanelID.uuidString,
            "activeRunId": "live-run",
            "restoreAuthority": true,
            "sessionState": lifecycle,
            "cmuxRuntime": runtime,
            "runs": [[
                "runId": "live-run",
                "restoreAuthority": true,
                "cmuxRuntime": runtime,
                "startedAt": 25.0,
                "updatedAt": updatedAt,
            ]],
            "startedAt": 25.0,
            "updatedAt": updatedAt,
        ]
        let slotJSON = try JSONSerialization.data(withJSONObject: [
            "sessionId": fixture.agent.sessionId,
            "updatedAt": updatedAt,
        ], options: [.sortedKeys])
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        try registry.apply(
            provider: "codex",
            records: [CmuxAgentSessionRegistry.Record(
                provider: "codex",
                sessionID: fixture.agent.sessionId,
                updatedAt: updatedAt,
                json: try JSONSerialization.data(withJSONObject: recordObject, options: [.sortedKeys])
            )],
            activeSlots: [
                CmuxAgentSessionRegistry.ActiveSlot(
                    provider: "codex",
                    scope: .workspace,
                    scopeID: fixture.source.id.uuidString,
                    sessionID: fixture.agent.sessionId,
                    updatedAt: updatedAt,
                    json: slotJSON
                ),
                CmuxAgentSessionRegistry.ActiveSlot(
                    provider: "codex",
                    scope: .surface,
                    scopeID: fixture.sourcePanelID.uuidString,
                    sessionID: fixture.agent.sessionId,
                    updatedAt: updatedAt,
                    json: slotJSON
                ),
            ]
        )

        let restored = Workspace()
        let mapping = restored.restoreSessionSnapshot(fixture.snapshot)
        let restoredPanelID = try #require(mapping[fixture.sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(!restoredPanel.isAgentHibernated)
        #expect(restored.restoredAgentSnapshotForTesting(panelId: restoredPanelID) == nil)
        #expect(!restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
        #expect(restoredPanel.surface.debugPendingSocketInputForTesting().items == 0)
        let restoredPanelSnapshot = try #require(
            restored.sessionSnapshot(includeScrollback: false).panels.first { $0.id == restoredPanelID }
        )
        #expect(restoredPanelSnapshot.terminal?.agent == nil)
        #expect(restoredPanelSnapshot.terminal?.hibernation == nil)
        #expect(restoredPanelSnapshot.terminal?.resumeBinding == nil)

        let snapshot = try registry.snapshot(provider: "codex")
        let stored = try #require(snapshot.records.first)
        let storedObject = try #require(JSONSerialization.jsonObject(with: stored.json) as? [String: Any])
        #expect(storedObject["workspaceId"] as? String == fixture.source.id.uuidString)
        #expect(storedObject["surfaceId"] as? String == fixture.sourcePanelID.uuidString)
        #expect(storedObject["sessionState"] as? String == lifecycle)
        #expect((storedObject["cmuxRuntime"] as? [String: Any])?["id"] as? String == "live-owner-runtime")
        #expect(Set(snapshot.activeSlots.map(\.scopeID)) == [
            fixture.source.id.uuidString,
            fixture.sourcePanelID.uuidString,
        ])
        #expect(!snapshot.activeSlots.contains { $0.scopeID == restoredPanelID.uuidString })
    }

    @Test func hibernationMovesTheSessionIntoTheCurrentCmuxRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-runtime-hibernation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "session": [
                    "sessionId": "session",
                    "workspaceId": "workspace",
                    "surfaceId": "surface",
                    "runId": "run",
                    "activeRunId": "run",
                    "restoreAuthority": true,
                    "cmuxRuntime": ["id": "old-runtime"],
                    "runs": [[
                        "runId": "run",
                        "restoreAuthority": true,
                        "cmuxRuntime": ["id": "old-runtime"],
                        "startedAt": 100.0,
                        "updatedAt": 100.0,
                    ]],
                    "startedAt": 100.0,
                    "updatedAt": 100.0,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
            .write(to: stateURL, options: .atomic)

        AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_RUNTIME_ID": "current-runtime",
                "CMUX_SOCKET_PATH": "/tmp/cmux-current.sock",
                "CMUX_BUNDLE_ID": "com.cmuxterm.current",
            ]
        ).setLifecycleSynchronously(
            kind: .codex,
            sessionId: "session",
            state: .hibernated,
            now: 200
        )

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let record = try #require(sessions["session"] as? [String: Any])
        #expect(record["sessionState"] as? String == "hibernated")
        let recordRuntime = try #require(record["cmuxRuntime"] as? [String: Any])
        #expect(recordRuntime["id"] as? String == "current-runtime")
        let runs = try #require(record["runs"] as? [[String: Any]])
        let runRuntime = try #require(runs.first?["cmuxRuntime"] as? [String: Any])
        #expect(runRuntime["id"] as? String == "current-runtime")
    }

    @Test func agentsTreeDefaultsToTheCallingCmuxRuntimeWhileAllIncludesHistory() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-runtime-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func record(sessionId: String, runId: String, runtimeId: String) -> [String: Any] {
            [
                "sessionId": sessionId,
                "workspaceId": "workspace-\(runtimeId)",
                "surfaceId": "surface-\(runtimeId)",
                "transcriptPath": "/tmp/\(sessionId).jsonl",
                "runId": runId,
                "activeRunId": runId,
                "restoreAuthority": true,
                "foregroundState": "completed",
                "workloads": [[
                    "id": "monitor-\(runtimeId)",
                    "kind": "monitor",
                    "phase": "watching",
                    "keepsSessionBusy": true,
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ]],
                "cmuxRuntime": [
                    "id": runtimeId,
                    "socketPath": "/tmp/cmux-debug-\(runtimeId).sock",
                    "bundleIdentifier": "com.cmuxterm.app.debug.\(runtimeId)",
                ],
                "runs": [[
                    "runId": runId,
                    "restoreAuthority": true,
                    "cmuxRuntime": [
                        "id": runtimeId,
                        "socketPath": "/tmp/cmux-debug-\(runtimeId).sock",
                        "bundleIdentifier": "com.cmuxterm.app.debug.\(runtimeId)",
                    ],
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ]],
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]
        }

        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "current-session": record(
                    sessionId: "current-session",
                    runId: "current-run",
                    runtimeId: "current"
                ),
                "other-session": record(
                    sessionId: "other-session",
                    runId: "other-run",
                    runtimeId: "other"
                ),
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_RUNTIME_ID"] = "current"

        let scoped = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!scoped.timedOut, Comment(rawValue: scoped.stdout))
        #expect(scoped.status == 0, Comment(rawValue: scoped.stdout))
        let scopedOutput = try #require(
            JSONSerialization.jsonObject(with: Data(scoped.stdout.utf8)) as? [String: Any]
        )
        let scopedNodes = try #require(scopedOutput["nodes"] as? [[String: Any]])
        #expect(scopedNodes.map { $0["session_id"] as? String } == ["current-session"])

        for filter in [
            ["--state", "monitoring"],
            ["--activity", "busy"],
            ["--work-kind", "monitor"],
        ] {
            let filteredList = runProcess(
                executablePath: cliPath,
                arguments: ["agents", "list"] + filter + ["--json"],
                environment: environment,
                timeout: 5
            )
            #expect(!filteredList.timedOut, Comment(rawValue: filteredList.stdout))
            #expect(filteredList.status == 0, Comment(rawValue: filteredList.stdout))
            let filteredOutput = try #require(
                JSONSerialization.jsonObject(with: Data(filteredList.stdout.utf8)) as? [String: Any]
            )
            let filteredSessions = try #require(filteredOutput["sessions"] as? [[String: Any]])
            #expect(filteredSessions.map { $0["session_id"] as? String } == ["current-session"])
        }

        let history = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!history.timedOut, Comment(rawValue: history.stdout))
        #expect(history.status == 0, Comment(rawValue: history.stdout))
        let historyOutput = try #require(
            JSONSerialization.jsonObject(with: Data(history.stdout.utf8)) as? [String: Any]
        )
        let historyNodes = try #require(historyOutput["nodes"] as? [[String: Any]])
        #expect(Set(historyNodes.compactMap { $0["session_id"] as? String }) == ["current-session", "other-session"])
    }

    @Test func agentsDefaultViewsExcludeEndedRunsFromTheCurrentRuntime() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-live-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime: [String: Any] = ["id": "current-runtime"]
        func record(
            sessionId: String,
            runId: String,
            foregroundState: String,
            endedAt: TimeInterval? = nil
        ) -> [String: Any] {
            var run: [String: Any] = [
                "runId": runId,
                "restoreAuthority": true,
                "cmuxRuntime": runtime,
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]
            run["endedAt"] = endedAt
            var result: [String: Any] = [
                "sessionId": sessionId,
                "workspaceId": "workspace",
                "surfaceId": "surface-\(sessionId)",
                "runId": runId,
                "activeRunId": runId,
                "restoreAuthority": true,
                "foregroundState": foregroundState,
                "cmuxRuntime": runtime,
                "runs": [run],
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]
            result["completedAt"] = endedAt
            return result
        }

        let codexStore: [String: Any] = [
            "version": 2,
            "sessions": [
                "ended-root": record(
                    sessionId: "ended-root",
                    runId: "ended-root-run",
                    foregroundState: "completed",
                    endedAt: 150
                ),
                "ended-child": record(
                    sessionId: "ended-child",
                    runId: "ended-child-run",
                    foregroundState: "completed",
                    endedAt: 160
                ),
                "live-codex": record(
                    sessionId: "live-codex",
                    runId: "live-codex-run",
                    foregroundState: "idle"
                ),
            ],
        ]
        let claudeStore: [String: Any] = [
            "version": 2,
            "sessions": [
                "live-claude": record(
                    sessionId: "live-claude",
                    runId: "live-claude-run",
                    foregroundState: "working"
                ),
            ],
        ]
        try JSONSerialization.data(withJSONObject: codexStore, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: claudeStore, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("claude-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_RUNTIME_ID"] = "current-runtime"

        for command in [["agents", "tree", "--json"], ["agents", "list", "--json"]] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: command,
                environment: environment,
                timeout: 5
            )
            #expect(!result.timedOut, Comment(rawValue: result.stdout))
            #expect(result.status == 0, Comment(rawValue: result.stdout))
            let output = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let rows = (output["nodes"] as? [[String: Any]]) ?? (output["sessions"] as? [[String: Any]])
            let sessionIds = Set(try #require(rows).compactMap { $0["session_id"] as? String })
            #expect(sessionIds == ["live-claude", "live-codex"], Comment(rawValue: result.stdout))
        }

        let history = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!history.timedOut, Comment(rawValue: history.stdout))
        #expect(history.status == 0, Comment(rawValue: history.stdout))
        let historyOutput = try #require(
            JSONSerialization.jsonObject(with: Data(history.stdout.utf8)) as? [String: Any]
        )
        let historyNodes = try #require(historyOutput["nodes"] as? [[String: Any]])
        #expect(Set(historyNodes.compactMap { $0["session_id"] as? String }) == [
            "ended-root", "ended-child", "live-claude", "live-codex",
        ])
    }

    @Test func agentsTreeKeepsDistinctSessionsThatShareAProcessGeneration() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-shared-process-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func writeStore(provider: String, sessionId: String) throws {
            let runtime: [String: Any] = ["id": "current-runtime"]
            let store: [String: Any] = [
                "version": 2,
                "sessions": [
                    sessionId: [
                        "sessionId": sessionId,
                        "workspaceId": "workspace",
                        "surfaceId": "surface-\(provider)",
                        "runId": "pid:4242@100",
                        "activeRunId": "pid:4242@100",
                        "restoreAuthority": true,
                        "cmuxRuntime": runtime,
                        "runs": [[
                            "runId": "pid:4242@100",
                            "pid": 4242,
                            "processStartedAt": 100.0,
                            "restoreAuthority": true,
                            "cmuxRuntime": runtime,
                            "startedAt": 100.0,
                            "updatedAt": 200.0,
                        ]],
                        "startedAt": 100.0,
                        "updatedAt": 200.0,
                    ],
                ],
            ]
            try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
                .write(to: root.appendingPathComponent("\(provider)-hook-sessions.json"), options: .atomic)
        }
        try writeStore(provider: "codex", sessionId: "codex-session")
        try writeStore(provider: "kimi", sessionId: "kimi-session")

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_RUNTIME_ID"] = "current-runtime"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let output = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let nodes = try #require(output["nodes"] as? [[String: Any]])
        #expect(Set(nodes.compactMap { $0["session_id"] as? String }) == ["codex-session", "kimi-session"])
    }

    @Test func agentsTreeNestsAChildThatSortsBeforeItsParent() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-child-before-parent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime: [String: Any] = ["id": "current-runtime"]
        func writeStore(
            provider: String,
            sessionId: String,
            runId: String,
            parentRunId: String? = nil,
            parentSessionId: String? = nil,
            relationship: String? = nil,
            restoreAuthority: Bool,
            startedAt: TimeInterval
        ) throws {
            var run: [String: Any] = [
                "runId": runId,
                "restoreAuthority": restoreAuthority,
                "cmuxRuntime": runtime,
                "startedAt": startedAt,
                "updatedAt": 300.0,
            ]
            run["parentRunId"] = parentRunId
            run["parentSessionId"] = parentSessionId
            run["relationship"] = relationship
            let store: [String: Any] = [
                "version": 2,
                "sessions": [
                    sessionId: [
                        "sessionId": sessionId,
                        "workspaceId": "workspace",
                        "surfaceId": "surface",
                        "runId": runId,
                        "activeRunId": runId,
                        "restoreAuthority": restoreAuthority,
                        "cmuxRuntime": runtime,
                        "runs": [run],
                        "startedAt": startedAt,
                        "updatedAt": 300.0,
                    ],
                ],
            ]
            try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
                .write(to: root.appendingPathComponent("\(provider)-hook-sessions.json"), options: .atomic)
        }

        // The child deliberately sorts before its parent in the flat node list.
        // Root selection must use composite graph identity so rendering still
        // starts at the parent and preserves the edge.
        try writeStore(
            provider: "claude",
            sessionId: "child-session",
            runId: "child-run",
            parentRunId: "parent-run",
            parentSessionId: "parent-session",
            relationship: "spawned",
            restoreAuthority: false,
            startedAt: 100.0
        )
        try writeStore(
            provider: "codex",
            sessionId: "parent-session",
            runId: "parent-run",
            restoreAuthority: true,
            startedAt: 200.0
        )

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_RUNTIME_ID"] = "current-runtime"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 2, Comment(rawValue: result.stdout))
        #expect(lines.first?.hasPrefix("codex parent-session") == true, Comment(rawValue: result.stdout))
        #expect(lines.last?.hasPrefix("└── claude child-session") == true, Comment(rawValue: result.stdout))
    }

    @MainActor
    private func makeHibernatedRestoreFixture(
        root: URL,
        sessionID: String
    ) throws -> (
        source: Workspace,
        snapshot: SessionWorkspaceSnapshot,
        sourcePanelID: UUID,
        agent: SessionRestorableAgentSnapshot
    ) {
        let source = Workspace()
        let sourcePanelID = try #require(source.focusedPanelId)
        let sourcePaneID = try #require(source.paneId(forPanelId: sourcePanelID))
        _ = try #require(source.newTerminalSurface(inPane: sourcePaneID, focus: true))
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: root.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex"],
                workingDirectory: root.path,
                environment: nil,
                capturedAt: 10,
                source: "agent-hook"
            )
        )
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelID })
        var terminal = try #require(snapshot.panels[panelIndex].terminal)
        terminal.agent = agent
        terminal.hibernation = SessionAgentHibernationSnapshot(
            hibernatedAt: 20,
            lastActivityAt: 10
        )
        terminal.wasAgentRunning = true
        snapshot.panels[panelIndex].terminal = terminal
        return (
            source: source,
            snapshot: snapshot,
            sourcePanelID: sourcePanelID,
            agent: agent
        )
    }

}
