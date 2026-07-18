import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxTerminal
import Darwin
import Foundation
import SQLite3
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
        #expect(!restoredPanel.hostedView.debugPortalActive)

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

        restored.setAgentHibernationAutoResumePresentationVisible(true)
        #expect(!restoredPanel.isAgentHibernated)
        _ = restored.reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        #expect(restoredPanel.hostedView.debugPortalActive)
    }

    @MainActor
    @Test func restoredHibernationAdoptionFailsFastWhileLegacyWriterIsLocked() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-hibernation-legacy-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let environmentOverrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "legacy-lock-runtime",
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
            sessionID: "legacy-lock-session"
        )
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
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
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)

        let descriptor = open(
            stateURL.path + ".lock",
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer { _ = flock(descriptor, LOCK_UN) }

        let targetSurfaceID = UUID()
        let elapsed = ContinuousClock().measure {
            let outcomes = AgentHookSessionStateWriter.recordRestoredHibernationOutcomes([
                .init(
                    agent: fixture.agent,
                    previousWorkspaceId: fixture.source.id,
                    previousSurfaceId: fixture.sourcePanelID,
                    workspaceId: UUID(),
                    surfaceId: targetSurfaceID
                ),
            ])
            #expect(outcomes[targetSurfaceID] == .unavailable)
        }
        #expect(elapsed < .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: registryURL.path))
    }

    @MainActor
    @Test func backgroundAdoptionWakesWhenLegacyWriterUnlocks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-legacy-unlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "legacy-unlock-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(root: root, sessionID: "legacy-unlock-session")
        let registry = try installHibernatedAuthority(
            root: root,
            registryURL: registryURL,
            agent: fixture.agent,
            workspaceId: fixture.source.id,
            surfaceId: fixture.sourcePanelID
        )
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let descriptor = open(
            stateURL.path + ".lock",
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        let lockDescriptor = try #require(descriptor >= 0 ? descriptor : nil)
        defer { Darwin.close(lockDescriptor) }
        #expect(flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0)
        defer { _ = flock(lockDescriptor, LOCK_UN) }

        let targetWorkspaceID = UUID()
        let targetSurfaceID = UUID()
        let request = AgentHookSessionStateWriter.RestoredHibernationAdoptionRequest(
            agent: fixture.agent,
            previousWorkspaceId: fixture.source.id,
            previousSurfaceId: fixture.sourcePanelID,
            workspaceId: targetWorkspaceID,
            surfaceId: targetSurfaceID
        )
        let waitStarted = AgentSessionAsyncGate()
        let operation = Task {
            await AgentHookSessionStateWriter.waitForRestoredHibernationOutcomes(
                [request],
                busyTimeoutMilliseconds: 2_000,
                legacyReadLockWaitWillBegin: {
                    Task { await waitStarted.open() }
                }
            )
        }
        await waitStarted.waitUntilOpen()
        #expect(flock(lockDescriptor, LOCK_UN) == 0)

        let outcomes = await operation.value
        #expect(outcomes[targetSurfaceID] == .adopted)
        let adopted = try #require(
            try registry.hookRecord(provider: "codex", sessionID: fixture.agent.sessionId)
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: adopted.json) as? [String: Any]
        )
        #expect(object["workspaceId"] as? String == targetWorkspaceID.uuidString)
        #expect(object["surfaceId"] as? String == targetSurfaceID.uuidString)
    }

    @MainActor
    @Test func backgroundAdoptionLegacyLockWaitHonorsCancellationAndDeadline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-legacy-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root
                .appendingPathComponent(CmuxAgentSessionRegistry.filename).path,
            "CMUX_RUNTIME_ID": "legacy-cancel-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "legacy-cancel-session",
            workingDirectory: root.path,
            launchCommand: nil
        )
        let targetSurfaceID = UUID()
        let request = AgentHookSessionStateWriter.RestoredHibernationAdoptionRequest(
            agent: agent,
            previousWorkspaceId: UUID(),
            previousSurfaceId: UUID(),
            workspaceId: UUID(),
            surfaceId: targetSurfaceID
        )
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let descriptor = open(
            stateURL.path + ".lock",
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        let lockDescriptor = try #require(descriptor >= 0 ? descriptor : nil)
        defer { Darwin.close(lockDescriptor) }
        #expect(flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0)
        defer { _ = flock(lockDescriptor, LOCK_UN) }

        let waitStarted = AgentSessionAsyncGate()
        let canceledOperation = Task {
            await AgentHookSessionStateWriter.waitForRestoredHibernationOutcomes(
                [request],
                busyTimeoutMilliseconds: 5_000,
                legacyReadLockWaitWillBegin: {
                    Task { await waitStarted.open() }
                }
            )
        }
        await waitStarted.waitUntilOpen()
        let cancellationStart = ContinuousClock.now
        canceledOperation.cancel()
        let canceledOutcomes = await canceledOperation.value
        let cancellationElapsed = cancellationStart.duration(to: .now)
        #expect(canceledOutcomes[targetSurfaceID] == .unavailable)
        #expect(cancellationElapsed < .seconds(1))

        let deadlineStart = ContinuousClock.now
        let deadlineOutcomes = await AgentHookSessionStateWriter.waitForRestoredHibernationOutcomes(
            [request],
            busyTimeoutMilliseconds: 100
        )
        let deadlineElapsed = deadlineStart.duration(to: .now)
        #expect(deadlineOutcomes[targetSurfaceID] == .unavailable)
        #expect(deadlineElapsed < .seconds(1))
    }

    @MainActor
    @Test func multipleProviderLegacyLocksShareOneBusyBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-legacy-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root
                .appendingPathComponent(CmuxAgentSessionRegistry.filename).path,
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let kinds: [RestorableAgentKind] = [.claude, .codex]
        var descriptors: [Int32] = []
        for kind in kinds {
            let stateURL = kind.hookStoreFileURL(
                homeDirectory: root.path,
                environment: overrides
            )
            let descriptor = open(
                stateURL.path + ".lock",
                O_CREAT | O_RDWR,
                mode_t(S_IRUSR | S_IWUSR)
            )
            let lockDescriptor = try #require(descriptor >= 0 ? descriptor : nil)
            #expect(flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0)
            descriptors.append(lockDescriptor)
        }
        defer {
            for descriptor in descriptors {
                _ = flock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            }
        }

        let requests = kinds.map { kind in
            AgentHookSessionStateWriter.RestoredHibernationAdoptionRequest(
                agent: SessionRestorableAgentSnapshot(
                    kind: kind,
                    sessionId: "\(kind.rawValue)-budget-session",
                    workingDirectory: root.path,
                    launchCommand: nil
                ),
                previousWorkspaceId: UUID(),
                previousSurfaceId: UUID(),
                workspaceId: UUID(),
                surfaceId: UUID()
            )
        }
        let started = ContinuousClock.now
        let outcomes = await AgentHookSessionStateWriter.waitForRestoredHibernationOutcomes(
            requests,
            busyTimeoutMilliseconds: 500
        )
        let elapsed = started.duration(to: .now)
        #expect(outcomes.values.allSatisfy { $0 == .unavailable })
        #expect(outcomes.count == 2)
        #expect(elapsed < .milliseconds(800))
    }

    @MainActor
    @Test func legacyProjectionDoesNotOverwriteAWriterThatClaimsTheAdoptedTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-projection-target-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let sessionID = "restored-session"
        let otherSessionID = "intervening-session"
        let previousWorkspaceID = UUID()
        let previousSurfaceID = UUID()
        let targetWorkspaceID = UUID()
        let targetSurfaceID = UUID()
        let restoredSlot: [String: Any] = ["sessionId": sessionID, "updatedAt": 10.0]
        let interveningSlot: [String: Any] = ["sessionId": otherSessionID, "updatedAt": 30.0]
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                sessionID: [
                    "sessionId": sessionID,
                    "workspaceId": previousWorkspaceID.uuidString,
                    "surfaceId": previousSurfaceID.uuidString,
                    "sessionState": "hibernated",
                    "restoreAuthority": true,
                    "startedAt": 1.0,
                    "updatedAt": 10.0,
                ],
                otherSessionID: [
                    "sessionId": otherSessionID,
                    "workspaceId": targetWorkspaceID.uuidString,
                    "surfaceId": targetSurfaceID.uuidString,
                    "sessionState": "active",
                    "restoreAuthority": true,
                    "startedAt": 25.0,
                    "updatedAt": 30.0,
                ],
            ],
            "activeSessionsByWorkspace": [
                previousWorkspaceID.uuidString: restoredSlot,
                targetWorkspaceID.uuidString: interveningSlot,
            ],
            "activeSessionsBySurface": [
                previousSurfaceID.uuidString: restoredSlot,
                targetSurfaceID.uuidString: interveningSlot,
            ],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: root.path,
            launchCommand: nil
        )
        let request = AgentHookSessionStateWriter.RestoredHibernationAdoptionRequest(
            agent: agent,
            previousWorkspaceId: previousWorkspaceID,
            previousSurfaceId: previousSurfaceID,
            workspaceId: targetWorkspaceID,
            surfaceId: targetSurfaceID,
            rebindWorkspaceActiveSlot: true
        )

        AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path]
        ).projectRestoredHibernationsToLegacy(
            provider: "codex",
            stateURL: stateURL,
            requests: [request],
            now: 20
        )

        let rootObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(rootObject["sessions"] as? [String: [String: Any]])
        #expect(sessions[sessionID]?["workspaceId"] as? String == previousWorkspaceID.uuidString)
        #expect(sessions[sessionID]?["surfaceId"] as? String == previousSurfaceID.uuidString)
        let workspaceSlots = try #require(
            rootObject["activeSessionsByWorkspace"] as? [String: [String: Any]]
        )
        let surfaceSlots = try #require(
            rootObject["activeSessionsBySurface"] as? [String: [String: Any]]
        )
        #expect(workspaceSlots[targetWorkspaceID.uuidString]?["sessionId"] as? String == otherSessionID)
        #expect(surfaceSlots[targetSurfaceID.uuidString]?["sessionId"] as? String == otherSessionID)
        #expect(workspaceSlots[previousWorkspaceID.uuidString]?["sessionId"] as? String == sessionID)
        #expect(surfaceSlots[previousSurfaceID.uuidString]?["sessionId"] as? String == sessionID)
    }

    @MainActor
    @Test func sameWorkspaceHibernationsTransferEverySurfaceAndOneWorkspaceOwnerInEitherOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-same-workspace-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for reversed in [false, true] {
            try { () throws -> Void in
                let scenarioRoot = root.appendingPathComponent(reversed ? "reversed" : "forward", isDirectory: true)
                try FileManager.default.createDirectory(at: scenarioRoot, withIntermediateDirectories: true)
                let registryURL = scenarioRoot.appendingPathComponent(CmuxAgentSessionRegistry.filename)
                let overrides = [
                    "CMUX_AGENT_HOOK_STATE_DIR": scenarioRoot.path,
                    "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
                    "CMUX_RUNTIME_ID": "same-workspace-runtime",
                ]
                let previous = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
                for (key, value) in overrides { setenv(key, value, 1) }
                defer {
                    for (key, value) in previous {
                        if let value { setenv(key, value, 1) } else { unsetenv(key) }
                    }
                }

                let previousWorkspaceID = UUID()
                let targetWorkspaceID = UUID()
                let sessionA = "same-workspace-a"
                let sessionB = "same-workspace-b"
                let previousSurfaceA = UUID()
                let previousSurfaceB = UUID()
                let targetSurfaceA = UUID()
                let targetSurfaceB = UUID()
                let slotA: [String: Any] = ["sessionId": sessionA, "updatedAt": 10.0]
                let slotB: [String: Any] = ["sessionId": sessionB, "updatedAt": 10.0]
                func record(_ sessionID: String, surfaceID: UUID) -> [String: Any] {
                    [
                        "sessionId": sessionID,
                        "workspaceId": previousWorkspaceID.uuidString,
                        "surfaceId": surfaceID.uuidString,
                        "sessionState": "hibernated",
                        "restoreAuthority": true,
                        "startedAt": 1.0,
                        "updatedAt": 10.0,
                    ]
                }
                try JSONSerialization.data(withJSONObject: [
                    "version": 2,
                    "sessions": [
                        sessionA: record(sessionA, surfaceID: previousSurfaceA),
                        sessionB: record(sessionB, surfaceID: previousSurfaceB),
                    ],
                    "activeSessionsByWorkspace": [previousWorkspaceID.uuidString: slotA],
                    "activeSessionsBySurface": [
                        previousSurfaceA.uuidString: slotA,
                        previousSurfaceB.uuidString: slotB,
                    ],
                ], options: [.sortedKeys]).write(
                    to: scenarioRoot.appendingPathComponent("pi-hook-sessions.json"),
                    options: .atomic
                )
                func request(
                    _ sessionID: String,
                    kind: RestorableAgentKind,
                    previous: UUID,
                    target: UUID
                ) -> AgentHookSessionStateWriter.RestoredHibernationAdoptionRequest {
                    .init(
                        agent: SessionRestorableAgentSnapshot(
                            kind: kind,
                            sessionId: sessionID,
                            workingDirectory: scenarioRoot.path,
                            launchCommand: nil
                        ),
                        previousWorkspaceId: previousWorkspaceID,
                        previousSurfaceId: previous,
                        workspaceId: targetWorkspaceID,
                        surfaceId: target
                    )
                }
                let requestA = request(
                    sessionA,
                    kind: .pi,
                    previous: previousSurfaceA,
                    target: targetSurfaceA
                )
                let requestB = request(
                    sessionB,
                    kind: .custom("pi"),
                    previous: previousSurfaceB,
                    target: targetSurfaceB
                )
                let adopted = AgentHookSessionStateWriter.recordRestoredHibernations(
                    reversed ? [requestB, requestA] : [requestA, requestB],
                    now: 20
                )

                #expect(adopted == [targetSurfaceA, targetSurfaceB])
                let snapshot = try CmuxAgentSessionRegistry(url: registryURL).snapshot(provider: "pi")
                let records = try Dictionary(uniqueKeysWithValues: snapshot.records.map { row in
                    let object = try #require(
                        JSONSerialization.jsonObject(with: row.json) as? [String: Any]
                    )
                    return (row.sessionID, object)
                })
                #expect(records[sessionA]?["workspaceId"] as? String == targetWorkspaceID.uuidString)
                #expect(records[sessionA]?["surfaceId"] as? String == targetSurfaceA.uuidString)
                #expect(records[sessionB]?["workspaceId"] as? String == targetWorkspaceID.uuidString)
                #expect(records[sessionB]?["surfaceId"] as? String == targetSurfaceB.uuidString)
                let workspaceSlots = snapshot.activeSlots.filter { $0.scope == .workspace }
                #expect(workspaceSlots.count == 1)
                #expect(workspaceSlots.first?.sessionID == sessionA)
                #expect(workspaceSlots.first?.scopeID == targetWorkspaceID.uuidString)
                let surfaceSlots = snapshot.activeSlots.filter { $0.scope == .surface }
                #expect(Dictionary(uniqueKeysWithValues: surfaceSlots.map { ($0.scopeID, $0.sessionID) }) == [
                    targetSurfaceA.uuidString: sessionA,
                    targetSurfaceB.uuidString: sessionB,
                ])
            }()
        }
    }

    @MainActor
    @Test func collidingTargetSurfaceRejectsOnlyThatSiblingInSameProviderBatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-same-provider-collision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "same-provider-collision-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let previousWorkspaceID = UUID()
        let targetWorkspaceID = UUID()
        let sessionA = "valid-sibling"
        let sessionB = "colliding-sibling"
        let collisionSession = "newer-surface-owner"
        let previousSurfaceA = UUID()
        let previousSurfaceB = UUID()
        let targetSurfaceA = UUID()
        let targetSurfaceB = UUID()
        let collisionWorkspace = UUID()
        let slotA: [String: Any] = ["sessionId": sessionA, "updatedAt": 10.0]
        let slotB: [String: Any] = ["sessionId": sessionB, "updatedAt": 10.0]
        let collisionSlot: [String: Any] = ["sessionId": collisionSession, "updatedAt": 30.0]
        func record(
            _ sessionID: String,
            workspaceID: UUID,
            surfaceID: UUID,
            state: String,
            updatedAt: TimeInterval
        ) -> [String: Any] {
            [
                "sessionId": sessionID,
                "workspaceId": workspaceID.uuidString,
                "surfaceId": surfaceID.uuidString,
                "sessionState": state,
                "restoreAuthority": true,
                "startedAt": 1.0,
                "updatedAt": updatedAt,
            ]
        }
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                sessionA: record(
                    sessionA,
                    workspaceID: previousWorkspaceID,
                    surfaceID: previousSurfaceA,
                    state: "hibernated",
                    updatedAt: 10
                ),
                sessionB: record(
                    sessionB,
                    workspaceID: previousWorkspaceID,
                    surfaceID: previousSurfaceB,
                    state: "hibernated",
                    updatedAt: 10
                ),
                collisionSession: record(
                    collisionSession,
                    workspaceID: collisionWorkspace,
                    surfaceID: targetSurfaceB,
                    state: "active",
                    updatedAt: 30
                ),
            ],
            "activeSessionsByWorkspace": [previousWorkspaceID.uuidString: slotA],
            "activeSessionsBySurface": [
                previousSurfaceA.uuidString: slotA,
                previousSurfaceB.uuidString: slotB,
                targetSurfaceB.uuidString: collisionSlot,
            ],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"),
            options: .atomic
        )
        func request(_ sessionID: String, previous: UUID, target: UUID) -> AgentHookSessionStateWriter.RestoredHibernationAdoptionRequest {
            .init(
                agent: SessionRestorableAgentSnapshot(
                    kind: .codex,
                    sessionId: sessionID,
                    workingDirectory: root.path,
                    launchCommand: nil
                ),
                previousWorkspaceId: previousWorkspaceID,
                previousSurfaceId: previous,
                workspaceId: targetWorkspaceID,
                surfaceId: target
            )
        }
        let requestA = request(sessionA, previous: previousSurfaceA, target: targetSurfaceA)
        let requestB = request(sessionB, previous: previousSurfaceB, target: targetSurfaceB)

        let adopted = AgentHookSessionStateWriter.recordRestoredHibernations(
            [requestB, requestA],
            now: 20
        )

        #expect(adopted == [targetSurfaceA])
        let snapshot = try CmuxAgentSessionRegistry(url: registryURL).snapshot(provider: "codex")
        let records = try Dictionary(uniqueKeysWithValues: snapshot.records.map { row in
            let object = try #require(JSONSerialization.jsonObject(with: row.json) as? [String: Any])
            return (row.sessionID, object)
        })
        #expect(records[sessionA]?["workspaceId"] as? String == targetWorkspaceID.uuidString)
        #expect(records[sessionA]?["surfaceId"] as? String == targetSurfaceA.uuidString)
        #expect(records[sessionB]?["workspaceId"] as? String == previousWorkspaceID.uuidString)
        #expect(records[sessionB]?["surfaceId"] as? String == previousSurfaceB.uuidString)
        #expect(records[collisionSession]?["surfaceId"] as? String == targetSurfaceB.uuidString)
        let workspaceSlots = snapshot.activeSlots.filter { $0.scope == .workspace }
        #expect(workspaceSlots.count == 1)
        #expect(workspaceSlots.first?.sessionID == sessionA)
        #expect(workspaceSlots.first?.scopeID == targetWorkspaceID.uuidString)
        let surfaceSlots = Dictionary(uniqueKeysWithValues: snapshot.activeSlots
            .filter { $0.scope == .surface }
            .map { ($0.scopeID, $0.sessionID) })
        #expect(surfaceSlots == [
            targetSurfaceA.uuidString: sessionA,
            previousSurfaceB.uuidString: sessionB,
            targetSurfaceB.uuidString: collisionSession,
        ])
    }

    @MainActor
    @Test func visibleClosedPanelRestoreRetriesAfterSQLiteOwnershipStoreRecovers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-closed-panel-locked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let environmentOverrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "closed-panel-lock-runtime",
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
            sessionID: "closed-panel-lock-session"
        )
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
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
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        _ = try registry.snapshotImportingLegacy(
            provider: "codex",
            legacyURL: stateURL,
            fileManager: .default
        )
        var database: OpaquePointer?
        #expect(sqlite3_open(registryURL.path, &database) == SQLITE_OK)
        let lockedDatabase = try #require(database)
        defer { sqlite3_close(lockedDatabase) }
        #expect(sqlite3_exec(lockedDatabase, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) }

        let destination = Workspace()
        let adoptionFinished = AgentSessionAsyncGate()
        destination.debugRestoredAgentHibernationAdoptionWaitDidFinish = { _ in
            Task { await adoptionFinished.open() }
        }
        destination.setAgentHibernationAutoResumePresentationVisible(true)
        let destinationPane = try #require(destination.bonsplitController.allPaneIds.first)
        let panelSnapshot = try #require(
            fixture.snapshot.panels.first { $0.id == fixture.sourcePanelID }
        )
        let entry = ClosedPanelHistoryEntry(
            workspaceId: destination.id,
            paneId: destinationPane.id,
            tabIndex: 0,
            snapshot: panelSnapshot
        )

        let restoredPanelID = try #require(destination.restoreClosedPanel(entry))
        let restoredPanel = try #require(destination.terminalPanel(for: restoredPanelID))
        #expect(restoredPanel.isAgentHibernated)
        #expect(destination.restoredAgentSnapshotForTesting(panelId: restoredPanelID)?.sessionId == fixture.agent.sessionId)
        #expect(!restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
        #expect(restoredPanel.surface.debugPendingSocketInputForTesting().items == 0)
        #expect(destination.debugRestoredAgentHibernationAdoptionWaitOperationCount == 1)
        #expect(destination.debugRestoredAgentHibernationAdoptionWaitInFlightCount == 1)

        let lockedSnapshot = try registry.snapshot(provider: "codex")
        let lockedRecord = try #require(
            lockedSnapshot.records.first { $0.sessionID == fixture.agent.sessionId }
        )
        let lockedObject = try #require(
            JSONSerialization.jsonObject(with: lockedRecord.json) as? [String: Any]
        )
        #expect(lockedObject["workspaceId"] as? String == fixture.source.id.uuidString)
        #expect(lockedObject["surfaceId"] as? String == fixture.sourcePanelID.uuidString)

        #expect(sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        await adoptionFinished.waitUntilOpen()

        #expect(!restoredPanel.isAgentHibernated)
        #expect(destination.debugRestoredAgentHibernationAdoptionWaitInFlightCount == 0)
        #expect(
            restoredPanel.surface.debugInitialInputForTesting()
                == (try #require(fixture.agent.resumeCommand)) + "\n"
        )
        #expect(restoredPanel.surface.debugPendingSocketInputForTesting().items == 0)
        let adoptedSnapshot = try registry.snapshot(provider: "codex")
        let adoptedRecord = try #require(
            adoptedSnapshot.records.first { $0.sessionID == fixture.agent.sessionId }
        )
        let adoptedObject = try #require(
            JSONSerialization.jsonObject(with: adoptedRecord.json) as? [String: Any]
        )
        #expect(adoptedObject["workspaceId"] as? String == destination.id.uuidString)
        #expect(adoptedObject["surfaceId"] as? String == restoredPanelID.uuidString)
        #expect(adoptedObject["sessionState"] as? String == "restoring")
    }

    @MainActor
    @Test func visibleClosedPanelRestoreAdoptsOwnershipBeforeOneResume() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-closed-panel-visible-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let environmentOverrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "closed-panel-visible-runtime",
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
            sessionID: "closed-panel-visible-session"
        )
        let destination = Workspace()
        destination.setAgentHibernationAutoResumePresentationVisible(true)
        let destinationPane = try #require(destination.bonsplitController.allPaneIds.first)
        let activeSlot: [String: Any] = [
            "sessionId": fixture.agent.sessionId,
            "updatedAt": 20.0,
        ]
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [fixture.agent.sessionId: [
                "sessionId": fixture.agent.sessionId,
                "workspaceId": destination.id.uuidString,
                "surfaceId": fixture.sourcePanelID.uuidString,
                "sessionState": "hibernated",
                "restoreAuthority": true,
                "startedAt": 10.0,
                "updatedAt": 20.0,
            ]],
            "activeSessionsByWorkspace": [destination.id.uuidString: activeSlot],
            "activeSessionsBySurface": [fixture.sourcePanelID.uuidString: activeSlot],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"),
            options: .atomic
        )
        let panelSnapshot = try #require(
            fixture.snapshot.panels.first { $0.id == fixture.sourcePanelID }
        )
        let entry = ClosedPanelHistoryEntry(
            workspaceId: destination.id,
            paneId: destinationPane.id,
            tabIndex: 0,
            snapshot: panelSnapshot
        )

        let restoredPanelID = try #require(destination.restoreClosedPanel(entry))
        let restoredPanel = try #require(destination.terminalPanel(for: restoredPanelID))
        let expectedResumeInput = try #require(fixture.agent.resumeCommand) + "\n"
        let registry = try CmuxAgentSessionRegistry(url: registryURL).snapshot(provider: "codex")
        let record = try #require(registry.records.first { $0.sessionID == fixture.agent.sessionId })
        let object = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])

        #expect(object["workspaceId"] as? String == destination.id.uuidString)
        #expect(object["surfaceId"] as? String == restoredPanelID.uuidString)
        #expect(Set(registry.activeSlots.map(\.scopeID)) == [
            destination.id.uuidString,
            restoredPanelID.uuidString,
        ])
        #expect(!restoredPanel.isAgentHibernated)
        #expect(restoredPanel.surface.debugInitialInputForTesting() == expectedResumeInput)

        destination.setAgentHibernationAutoResumePresentationVisible(true)
        #expect(restoredPanel.surface.debugInitialInputForTesting() == expectedResumeInput)
        #expect(restoredPanel.surface.debugPendingSocketInputForTesting().items == 0)
    }

    @MainActor
    @Test func closingPanelCancelsPendingBackgroundAdoptionWithoutApplyingItsResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-adoption-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "restore-cancel-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(root: root, sessionID: "restore-cancel-session")
        let registry = try installHibernatedAuthority(
            root: root,
            registryURL: registryURL,
            agent: fixture.agent,
            workspaceId: fixture.source.id,
            surfaceId: fixture.sourcePanelID
        )
        var database: OpaquePointer?
        #expect(sqlite3_open(registryURL.path, &database) == SQLITE_OK)
        let lockedDatabase = try #require(database)
        defer { sqlite3_close(lockedDatabase) }
        #expect(sqlite3_exec(lockedDatabase, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) }

        let handlerStarted = AgentSessionAsyncGate()
        let releaseHandler = AgentSessionAsyncGate()
        let handlerFinished = AgentSessionAsyncGate()
        let destination = Workspace()
        destination.debugRestoredAgentHibernationAdoptionWaitHandler = { requests in
            await handlerStarted.open()
            await releaseHandler.waitUntilOpen()
            return Dictionary(uniqueKeysWithValues: requests.map { ($0.surfaceId, .adopted) })
        }
        destination.debugRestoredAgentHibernationAdoptionWaitDidFinish = { _ in
            Task { await handlerFinished.open() }
        }
        destination.setAgentHibernationAutoResumePresentationVisible(true)
        let paneId = try #require(destination.bonsplitController.allPaneIds.first)
        let panelSnapshot = try #require(
            fixture.snapshot.panels.first { $0.id == fixture.sourcePanelID }
        )
        let panelId = try #require(destination.restoreClosedPanel(.init(
            workspaceId: destination.id,
            paneId: paneId.id,
            tabIndex: 0,
            snapshot: panelSnapshot
        )))
        await handlerStarted.waitUntilOpen()

        #expect(destination.closePanel(panelId, force: true))
        #expect(destination.terminalPanel(for: panelId) == nil)
        #expect(destination.debugRestoredAgentHibernationAdoptionWaitCancellationCount == 1)
        #expect(sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        await releaseHandler.open()
        await handlerFinished.waitUntilOpen()

        #expect(destination.debugRestoredAgentHibernationAdoptionWaitInFlightCount == 0)
        let snapshot = try registry.snapshot(provider: "codex")
        let record = try #require(snapshot.records.first)
        let object = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])
        #expect(object["workspaceId"] as? String == fixture.source.id.uuidString)
        #expect(object["surfaceId"] as? String == fixture.sourcePanelID.uuidString)
        #expect(object["sessionState"] as? String == "hibernated")
    }

    @MainActor
    @Test func repeatedVisibilityDoesNotDuplicatePendingBackgroundAdoption() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-adoption-dedup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "restore-dedup-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(root: root, sessionID: "restore-dedup-session")
        _ = try installHibernatedAuthority(
            root: root,
            registryURL: registryURL,
            agent: fixture.agent,
            workspaceId: fixture.source.id,
            surfaceId: fixture.sourcePanelID
        )
        var database: OpaquePointer?
        #expect(sqlite3_open(registryURL.path, &database) == SQLITE_OK)
        let lockedDatabase = try #require(database)
        defer { sqlite3_close(lockedDatabase) }
        #expect(sqlite3_exec(lockedDatabase, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) }

        let handlerStarted = AgentSessionAsyncGate()
        let releaseHandler = AgentSessionAsyncGate()
        let handlerFinished = AgentSessionAsyncGate()
        let destination = Workspace()
        destination.debugRestoredAgentHibernationAdoptionWaitHandler = { requests in
            await handlerStarted.open()
            await releaseHandler.waitUntilOpen()
            return Dictionary(uniqueKeysWithValues: requests.map { ($0.surfaceId, .unavailable) })
        }
        destination.debugRestoredAgentHibernationAdoptionWaitDidFinish = { _ in
            Task { await handlerFinished.open() }
        }
        destination.setAgentHibernationAutoResumePresentationVisible(true)
        let paneId = try #require(destination.bonsplitController.allPaneIds.first)
        let panelSnapshot = try #require(
            fixture.snapshot.panels.first { $0.id == fixture.sourcePanelID }
        )
        let panelId = try #require(destination.restoreClosedPanel(.init(
            workspaceId: destination.id,
            paneId: paneId.id,
            tabIndex: 0,
            snapshot: panelSnapshot
        )))
        let panel = try #require(destination.terminalPanel(for: panelId))
        await handlerStarted.waitUntilOpen()

        for _ in 0..<5 {
            destination.setAgentHibernationAutoResumePresentationVisible(true)
        }
        #expect(destination.debugRestoredAgentHibernationAdoptionWaitOperationCount == 1)
        #expect(destination.debugRestoredAgentHibernationAdoptionWaitInFlightCount == 1)
        #expect(panel.isAgentHibernated)
        #expect(!panel.surface.debugInitialInputMetadata().hasInitialInput)

        #expect(sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        await releaseHandler.open()
        await handlerFinished.waitUntilOpen()
        #expect(destination.debugRestoredAgentHibernationAdoptionWaitOperationCount == 1)
        #expect(destination.debugRestoredAgentHibernationAdoptionWaitInFlightCount == 0)
        #expect(panel.isAgentHibernated)
        #expect(!panel.surface.debugInitialInputMetadata().hasInitialInput)
    }

    @MainActor
    @Test func closingPanelAfterAdoptionCommitReleasesExactDurableGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-adoption-postcommit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "restore-postcommit-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(root: root, sessionID: "restore-postcommit-session")
        let registry = try installHibernatedAuthority(
            root: root,
            registryURL: registryURL,
            agent: fixture.agent,
            workspaceId: fixture.source.id,
            surfaceId: fixture.sourcePanelID
        )
        var database: OpaquePointer?
        #expect(sqlite3_open(registryURL.path, &database) == SQLITE_OK)
        let lockedDatabase = try #require(database)
        defer { sqlite3_close(lockedDatabase) }
        #expect(sqlite3_exec(lockedDatabase, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) }

        let handlerStarted = AgentSessionAsyncGate()
        let allowCommit = AgentSessionAsyncGate()
        let commitFinished = AgentSessionAsyncGate()
        let allowDelivery = AgentSessionAsyncGate()
        let handlerFinished = AgentSessionAsyncGate()
        let destination = Workspace()
        destination.debugRestoredAgentHibernationAdoptionWaitHandler = { requests in
            await handlerStarted.open()
            await allowCommit.waitUntilOpen()
            let outcomes = await AgentHookSessionStateWriter.waitForRestoredHibernationOutcomes(
                requests
            )
            await commitFinished.open()
            await allowDelivery.waitUntilOpen()
            return outcomes
        }
        destination.debugRestoredAgentHibernationAdoptionWaitDidFinish = { _ in
            Task { await handlerFinished.open() }
        }
        destination.setAgentHibernationAutoResumePresentationVisible(true)
        let paneId = try #require(destination.bonsplitController.allPaneIds.first)
        let panelSnapshot = try #require(
            fixture.snapshot.panels.first { $0.id == fixture.sourcePanelID }
        )
        let panelId = try #require(destination.restoreClosedPanel(.init(
            workspaceId: destination.id,
            paneId: paneId.id,
            tabIndex: 0,
            snapshot: panelSnapshot
        )))
        await handlerStarted.waitUntilOpen()

        #expect(sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        await allowCommit.open()
        await commitFinished.waitUntilOpen()
        let committed = try registry.snapshot(provider: "codex")
        let committedRecord = try #require(committed.records.first)
        let committedObject = try #require(
            JSONSerialization.jsonObject(with: committedRecord.json) as? [String: Any]
        )
        #expect(committedObject["surfaceId"] as? String == panelId.uuidString)
        #expect(committedObject["cmuxRestoreAdoptionId"] is String)

        #expect(destination.closePanel(panelId, force: true))
        await allowDelivery.open()
        await handlerFinished.waitUntilOpen()

        let released = try registry.snapshot(provider: "codex")
        let releasedRecord = try #require(released.records.first)
        let releasedObject = try #require(
            JSONSerialization.jsonObject(with: releasedRecord.json) as? [String: Any]
        )
        #expect(releasedObject["restoreAuthority"] as? Bool == false)
        #expect(releasedObject["sessionState"] as? String == "ended")
        #expect(releasedObject["completedAt"] is TimeInterval)
        #expect(releasedObject["cmuxRestoreAdoptionId"] == nil)
        #expect(!released.activeSlots.contains { $0.sessionID == fixture.agent.sessionId })
        #expect(destination.debugRestoredAgentHibernationAdoptionWaitInFlightCount == 0)
    }

    @MainActor
    @Test func workspaceTeardownAfterAdoptionCommitPreservesNextLaunchAuthority() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-adoption-teardown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "restore-teardown-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(root: root, sessionID: "restore-teardown-session")
        let registry = try installHibernatedAuthority(
            root: root,
            registryURL: registryURL,
            agent: fixture.agent,
            workspaceId: fixture.source.id,
            surfaceId: fixture.sourcePanelID
        )
        var database: OpaquePointer?
        #expect(sqlite3_open(registryURL.path, &database) == SQLITE_OK)
        let lockedDatabase = try #require(database)
        defer { sqlite3_close(lockedDatabase) }
        #expect(sqlite3_exec(lockedDatabase, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) }

        let handlerStarted = AgentSessionAsyncGate()
        let allowCommit = AgentSessionAsyncGate()
        let commitFinished = AgentSessionAsyncGate()
        let allowDelivery = AgentSessionAsyncGate()
        let ownerReleased = AgentSessionAsyncGate()
        weak var weakDestination: Workspace?
        var destination: Workspace? = Workspace()
        weakDestination = destination
        var destinationWorkspaceID: UUID?
        var restoredPanelID: UUID?
        do {
            let workspace = try #require(destination)
            destinationWorkspaceID = workspace.id
            workspace.debugRestoredAgentHibernationAdoptionWaitHandler = { requests in
                await handlerStarted.open()
                await allowCommit.waitUntilOpen()
                let outcomes = await AgentHookSessionStateWriter.waitForRestoredHibernationOutcomes(
                    requests
                )
                await commitFinished.open()
                await allowDelivery.waitUntilOpen()
                return outcomes
            }
            workspace.debugRestoredAgentHibernationAdoptionWaitOwnerReleased = {
                Task { await ownerReleased.open() }
            }
            workspace.setAgentHibernationAutoResumePresentationVisible(true)
            let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
            let panelSnapshot = try #require(
                fixture.snapshot.panels.first { $0.id == fixture.sourcePanelID }
            )
            restoredPanelID = try #require(workspace.restoreClosedPanel(.init(
                workspaceId: workspace.id,
                paneId: paneId.id,
                tabIndex: 0,
                snapshot: panelSnapshot
            )))
            await handlerStarted.waitUntilOpen()
        }

        #expect(sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        await allowCommit.open()
        await commitFinished.waitUntilOpen()
        let workspaceID = try #require(destinationWorkspaceID)
        let panelID = try #require(restoredPanelID)
        let committed = try registry.snapshot(provider: "codex")
        let committedRecord = try #require(committed.records.first)
        let committedObject = try #require(
            JSONSerialization.jsonObject(with: committedRecord.json) as? [String: Any]
        )
        #expect(committedObject["workspaceId"] as? String == workspaceID.uuidString)
        #expect(committedObject["surfaceId"] as? String == panelID.uuidString)
        #expect(committedObject["cmuxRestoreAdoptionId"] is String)

        destination = nil
        #expect(weakDestination == nil)
        await allowDelivery.open()
        await ownerReleased.waitUntilOpen()

        let preserved = try registry.snapshot(provider: "codex")
        let preservedRecord = try #require(preserved.records.first)
        let preservedObject = try #require(
            JSONSerialization.jsonObject(with: preservedRecord.json) as? [String: Any]
        )
        #expect(preservedObject["workspaceId"] as? String == workspaceID.uuidString)
        #expect(preservedObject["surfaceId"] as? String == panelID.uuidString)
        #expect(preservedObject["restoreAuthority"] as? Bool == true)
        #expect(preservedObject["sessionState"] as? String == "hibernated")
        #expect(preservedObject["completedAt"] == nil)
        #expect(preservedObject["cmuxRestoreAdoptionId"] is String)
        #expect(preserved.activeSlots.contains { slot in
            slot.sessionID == fixture.agent.sessionId
                && (slot.scopeID == workspaceID.uuidString || slot.scopeID == panelID.uuidString)
        })
    }

    @MainActor
    @Test func workspaceTeardownBeforeAdoptionCommitKeepsCanonicalBindingAdoptableByNextLaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-adoption-precommit-teardown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "restore-precommit-teardown-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        weak var weakSource: Workspace?
        let fixture: (
            snapshot: SessionWorkspaceSnapshot,
            sourceWorkspaceID: UUID,
            sourcePanelID: UUID,
            agent: SessionRestorableAgentSnapshot
        ) = try {
            let fixture = try makeHibernatedRestoreFixture(
                root: root,
                sessionID: "restore-precommit-teardown-session"
            )
            weakSource = fixture.source
            _ = try installHibernatedAuthority(
                root: root,
                registryURL: registryURL,
                agent: fixture.agent,
                workspaceId: fixture.source.id,
                surfaceId: fixture.sourcePanelID
            )
            return (
                fixture.snapshot,
                fixture.source.id,
                fixture.sourcePanelID,
                fixture.agent
            )
        }()
        #expect(weakSource == nil)
        let registry = CmuxAgentSessionRegistry(url: registryURL)

        var database: OpaquePointer?
        #expect(sqlite3_open(registryURL.path, &database) == SQLITE_OK)
        let lockedDatabase = try #require(database)
        defer { sqlite3_close(lockedDatabase) }
        #expect(sqlite3_exec(lockedDatabase, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        var databaseIsLocked = true
        defer {
            if databaseIsLocked {
                sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil)
            }
        }

        let adoptionWaitStarted = AgentSessionAsyncGate()
        let allowCanceledWaitToFinish = AgentSessionAsyncGate()
        let launchAOwnerReleased = AgentSessionAsyncGate()
        weak var weakLaunchA: Workspace?
        var launchA: Workspace? = Workspace()
        weakLaunchA = launchA
        var launchAWorkspaceID: UUID?
        var launchAPanelID: UUID?
        var launchASnapshot: SessionWorkspaceSnapshot?
        do {
            let workspace = try #require(launchA)
            launchAWorkspaceID = workspace.id
            workspace.debugRestoredAgentHibernationAdoptionWaitHandler = { requests in
                await adoptionWaitStarted.open()
                await allowCanceledWaitToFinish.waitUntilOpen()
                return Dictionary(uniqueKeysWithValues: requests.map { ($0.surfaceId, .unavailable) })
            }
            workspace.debugRestoredAgentHibernationAdoptionWaitOwnerReleased = {
                Task { await launchAOwnerReleased.open() }
            }
            workspace.setAgentHibernationAutoResumePresentationVisible(true)
            let mapping = workspace.restoreSessionSnapshot(fixture.snapshot)
            let panelID = try #require(mapping[fixture.sourcePanelID])
            launchAPanelID = panelID
            let panel = try #require(workspace.terminalPanel(for: panelID))
            #expect(panel.isAgentHibernated)
            await adoptionWaitStarted.waitUntilOpen()
            launchASnapshot = workspace.sessionSnapshot(includeScrollback: false)
        }
        let workspaceIDAfterFirstRestore = try #require(launchAWorkspaceID)
        let panelIDAfterFirstRestore = try #require(launchAPanelID)
        let snapshotAfterFirstRestore = try #require(launchASnapshot)
        #expect(workspaceIDAfterFirstRestore != fixture.sourceWorkspaceID)
        #expect(snapshotAfterFirstRestore.workspaceId == workspaceIDAfterFirstRestore)
        #expect(snapshotAfterFirstRestore.panels.contains { $0.id == panelIDAfterFirstRestore })

        launchA = nil
        #expect(weakLaunchA == nil)
        #expect(sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        databaseIsLocked = false
        await allowCanceledWaitToFinish.open()
        await launchAOwnerReleased.waitUntilOpen()

        let precommitSnapshot = try registry.snapshot(provider: "codex")
        let precommitRecord = try #require(
            precommitSnapshot.records.first { $0.sessionID == fixture.agent.sessionId }
        )
        let precommitObject = try #require(
            JSONSerialization.jsonObject(with: precommitRecord.json) as? [String: Any]
        )
        #expect(precommitObject["workspaceId"] as? String == fixture.sourceWorkspaceID.uuidString)
        #expect(precommitObject["surfaceId"] as? String == fixture.sourcePanelID.uuidString)
        #expect(Set(precommitSnapshot.activeSlots.map(\.scopeID)) == [
            fixture.sourceWorkspaceID.uuidString,
            fixture.sourcePanelID.uuidString,
        ])

        let launchB = Workspace()
        let launchBMapping = launchB.restoreSessionSnapshot(snapshotAfterFirstRestore)
        let launchBPanelID = try #require(launchBMapping[panelIDAfterFirstRestore])
        let launchBPanel = try #require(launchB.terminalPanel(for: launchBPanelID))
        #expect(launchB.id != workspaceIDAfterFirstRestore)
        #expect(launchBPanel.isAgentHibernated)
        #expect(
            launchB.restoredAgentSnapshotForTesting(panelId: launchBPanelID)?.sessionId
                == fixture.agent.sessionId
        )

        let reboundSnapshot = try registry.snapshot(provider: "codex")
        let reboundRecord = try #require(
            reboundSnapshot.records.first { $0.sessionID == fixture.agent.sessionId }
        )
        let reboundObject = try #require(
            JSONSerialization.jsonObject(with: reboundRecord.json) as? [String: Any]
        )
        #expect(reboundObject["workspaceId"] as? String == launchB.id.uuidString)
        #expect(reboundObject["surfaceId"] as? String == launchBPanelID.uuidString)
        #expect(reboundObject["sessionState"] as? String == "hibernated")
        #expect(Set(reboundSnapshot.activeSlots.map(\.scopeID)) == [
            launchB.id.uuidString,
            launchBPanelID.uuidString,
        ])
    }

    @MainActor
    @Test func hiddenPanelRetainsCommittedAdoptionAndResumesWhenVisibleAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-adoption-hidden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "restore-hidden-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(root: root, sessionID: "restore-hidden-session")
        let registry = try installHibernatedAuthority(
            root: root,
            registryURL: registryURL,
            agent: fixture.agent,
            workspaceId: fixture.source.id,
            surfaceId: fixture.sourcePanelID
        )
        var database: OpaquePointer?
        #expect(sqlite3_open(registryURL.path, &database) == SQLITE_OK)
        let lockedDatabase = try #require(database)
        defer { sqlite3_close(lockedDatabase) }
        #expect(sqlite3_exec(lockedDatabase, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) }

        let handlerStarted = AgentSessionAsyncGate()
        let releaseHandler = AgentSessionAsyncGate()
        let handlerFinished = AgentSessionAsyncGate()
        let destination = Workspace()
        destination.debugRestoredAgentHibernationAdoptionWaitHandler = { requests in
            await handlerStarted.open()
            await releaseHandler.waitUntilOpen()
            return await AgentHookSessionStateWriter.waitForRestoredHibernationOutcomes(requests)
        }
        destination.debugRestoredAgentHibernationAdoptionWaitDidFinish = { _ in
            Task { await handlerFinished.open() }
        }
        destination.setAgentHibernationAutoResumePresentationVisible(true)
        let paneId = try #require(destination.bonsplitController.allPaneIds.first)
        let panelSnapshot = try #require(
            fixture.snapshot.panels.first { $0.id == fixture.sourcePanelID }
        )
        let panelId = try #require(destination.restoreClosedPanel(.init(
            workspaceId: destination.id,
            paneId: paneId.id,
            tabIndex: 0,
            snapshot: panelSnapshot
        )))
        let panel = try #require(destination.terminalPanel(for: panelId))
        await handlerStarted.waitUntilOpen()

        destination.setAgentHibernationAutoResumePresentationVisible(false)
        #expect(sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        await releaseHandler.open()
        await handlerFinished.waitUntilOpen()

        #expect(panel.isAgentHibernated)
        #expect(!panel.surface.debugInitialInputMetadata().hasInitialInput)
        let adopted = try registry.snapshot(provider: "codex")
        let adoptedRecord = try #require(adopted.records.first)
        let adoptedObject = try #require(
            JSONSerialization.jsonObject(with: adoptedRecord.json) as? [String: Any]
        )
        #expect(adoptedObject["workspaceId"] as? String == destination.id.uuidString)
        #expect(adoptedObject["surfaceId"] as? String == panelId.uuidString)
        #expect(adoptedObject["sessionState"] as? String == "hibernated")

        destination.setAgentHibernationAutoResumePresentationVisible(true)
        #expect(!panel.isAgentHibernated)
        #expect(panel.surface.debugInitialInputForTesting() == (try #require(fixture.agent.resumeCommand)) + "\n")
        let resumed = try registry.snapshot(provider: "codex")
        let resumedRecord = try #require(resumed.records.first)
        let resumedObject = try #require(
            JSONSerialization.jsonObject(with: resumedRecord.json) as? [String: Any]
        )
        #expect(resumedObject["sessionState"] as? String == "restoring")
        #expect(resumedObject["cmuxRestoreAdoptionId"] == nil)
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
        let record = try #require(
            registrySnapshot.records.first { $0.sessionID == fixture.agent.sessionId }
        )
        let object = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])
        #expect(object["workspaceId"] as? String == restored.id.uuidString)
        #expect(object["surfaceId"] as? String == restoredPanelID.uuidString)
        #expect(object["sessionState"] as? String == "hibernated")
        #expect(Set(registrySnapshot.activeSlots.map(\.scopeID)) == [
            restored.id.uuidString,
            restoredPanelID.uuidString,
        ])

        #expect(!restoredPanel.hostedView.debugPortalActive)
        restored.setAgentHibernationAutoResumePresentationVisible(true)
        #expect(!restoredPanel.isAgentHibernated)
        _ = restored.reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        #expect(restoredPanel.hostedView.debugPortalActive)
    }

    @MainActor
    @Test func alreadyVisibleWorkspaceResumesOnceAfterRestoredOwnershipAdoption() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-hibernation-already-visible-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let environmentOverrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "already-visible-runtime",
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
            sessionID: "already-visible-session"
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

        let restored = Workspace()
        restored.setAgentHibernationAutoResumePresentationVisible(true)
        let adoptionBatch = RestoredAgentHibernationAdoptionBatch()
        let mapping = restored.restoreSessionSnapshot(
            fixture.snapshot,
            restoredAgentHibernationAdoptionBatch: adoptionBatch
        )
        let restoredPanelID = try #require(mapping[fixture.sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        let expectedResumeInput = try #require(fixture.agent.resumeCommand) + "\n"
        #expect(restoredPanel.isAgentHibernated)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)
        restoredPanel.hostedView.frame = contentView.bounds
        contentView.addSubview(restoredPanel.hostedView)
        restoredPanel.hostedView.setVisibleInUI(true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()

        adoptionBatch.finalize()

        #expect(!restoredPanel.isAgentHibernated)
        #expect(restoredPanel.surface.debugInitialInputForTesting() == expectedResumeInput)
        #expect(restoredPanel.surface.debugDesiredFocusState())
        #expect(restoredPanel.hostedView.debugRenderStats().desiredFocus)
        let registry = try CmuxAgentSessionRegistry(url: registryURL).snapshot(provider: "codex")
        let record = try #require(registry.records.first { $0.sessionID == fixture.agent.sessionId })
        let object = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])
        #expect(object["workspaceId"] as? String == restored.id.uuidString)
        #expect(object["surfaceId"] as? String == restoredPanelID.uuidString)

        restored.setAgentHibernationAutoResumePresentationVisible(true)
        #expect(restoredPanel.surface.debugInitialInputForTesting() == expectedResumeInput)
        #expect(restoredPanel.surface.debugPendingSocketInputForTesting().items == 0)
    }

    @MainActor
    @Test func unavailableResumePreparationDoesNotConsumeDurableAuthority() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-resume-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "resume-preflight-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(root: root, sessionID: "resume-preflight-session")
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

        let restored = Workspace()
        let mapping = restored.restoreSessionSnapshot(fixture.snapshot)
        let restoredPanelID = try #require(mapping[fixture.sourcePanelID])
        let panel = try #require(restored.terminalPanel(for: restoredPanelID))
        #expect(panel.isAgentHibernated)
        panel.surface.beginPortalCloseLifecycle(reason: "test.resumePreflight")

        #expect(!restored.resumeAgentHibernation(panelId: restoredPanelID, focus: false))
        #expect(panel.isAgentHibernated)
        #expect(!panel.surface.debugInitialInputMetadata().hasInitialInput)
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 0)
        let registry = try CmuxAgentSessionRegistry(url: registryURL).snapshot(provider: "codex")
        let record = try #require(registry.records.first)
        let object = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])
        #expect(object["sessionState"] as? String == "hibernated")
        #expect(object["workspaceId"] as? String == restored.id.uuidString)
        #expect(object["surfaceId"] as? String == restoredPanelID.uuidString)
    }

    @MainActor
    @Test func pendingInputImmediatelyResumesAfterDurableHibernationCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-live-hibernation-immediate-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let runtimeID = "live-hibernation-runtime"
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": runtimeID,
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let workspace = Workspace(workingDirectory: root.path)
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))
        let sessionID = "live-hibernation-session"
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
        #expect(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: agent.kind.rawValue,
                command: try #require(agent.resumeCommand),
                cwd: root.path,
                checkpointId: sessionID,
                source: "agent-hook",
                autoResume: false,
                updatedAt: 20
            ),
            panelId: panelID
        ))
        let runtime: [String: Any] = ["id": runtimeID]
        let record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": workspace.id.uuidString,
            "surfaceId": panelID.uuidString,
            "sessionState": "active",
            "restoreAuthority": true,
            "activeRunId": "live-run",
            "cmuxRuntime": runtime,
            "runs": [[
                "runId": "live-run",
                "restoreAuthority": true,
                "cmuxRuntime": runtime,
                "startedAt": 10.0,
                "updatedAt": 20.0,
            ]],
            "startedAt": 10.0,
            "updatedAt": 20.0,
        ]
        let slotObject: [String: Any] = ["sessionId": sessionID, "updatedAt": 20.0]
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionID: record],
            "activeSessionsByWorkspace": [workspace.id.uuidString: slotObject],
            "activeSessionsBySurface": [panelID.uuidString: slotObject],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"),
            options: .atomic
        )
        let slotJSON = try JSONSerialization.data(withJSONObject: slotObject, options: [.sortedKeys])
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        try registry.apply(
            provider: "codex",
            records: [.init(
                provider: "codex",
                sessionID: sessionID,
                updatedAt: 20,
                json: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            )],
            activeSlots: [
                .init(
                    provider: "codex",
                    scope: .workspace,
                    scopeID: workspace.id.uuidString,
                    sessionID: sessionID,
                    updatedAt: 20,
                    json: slotJSON
                ),
                .init(
                    provider: "codex",
                    scope: .surface,
                    scopeID: panelID.uuidString,
                    sessionID: sessionID,
                    updatedAt: 20,
                    json: slotJSON
                ),
            ]
        )

        panel.surface.installRuntimeSurfaceForTesting(
            UnsafeMutableRawPointer(bitPattern: 0x7867)!
        )
        let nativeFreeStarted = AgentSessionAsyncGate()
        let releaseNativeFree = DispatchSemaphore(value: 0)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            Task { await nativeFreeStarted.open() }
            releaseNativeFree.wait()
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        let hibernation = Task { @MainActor in
            await workspace.enterAgentHibernation(
                panelId: panelID,
                agent: agent,
                lastActivityAt: Date(timeIntervalSince1970: 10),
                finalValidation: { true }
            )
        }
        await nativeFreeStarted.waitUntilOpen()
        #expect(panel.surface.sendNamedKey("enter") == .queued)
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 1)
        releaseNativeFree.signal()

        #expect(await hibernation.value)
        #expect(!panel.isAgentHibernated)
        let resumeCommand = try #require(agent.resumeCommand)
        #expect(panel.surface.debugInitialInputForTesting() == resumeCommand + "\n")
        let saved = try registry.snapshot(provider: "codex")
        let savedRecord = try #require(saved.records.first)
        let savedObject = try #require(
            JSONSerialization.jsonObject(with: savedRecord.json) as? [String: Any]
        )
        #expect(savedObject["sessionState"] as? String == "restoring")
        #expect((savedObject["cmuxRuntime"] as? [String: Any])?["id"] as? String == runtimeID)
    }

    @MainActor
    @Test func lockedDurableHibernationCommitRestoresExactLiveRuntime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-live-hibernation-contention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let runtimeID = "live-hibernation-contention-runtime"
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": runtimeID,
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeLiveHibernationAuthorityFixture(
            root: root,
            runtimeID: runtimeID,
            sessionID: "live-hibernation-contention-session"
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        fixture.panel.surface.installRuntimeSurfaceForTesting(runtimeSurface)
        let nativeFreeCalled = AtomicBooleanGate(false)
        let cleanupFinished = AgentSessionAsyncGate()
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { pointer in
            nativeFreeCalled.storeRelease(true)
            pointer.deallocate()
            Task { await cleanupFinished.open() }
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        var database: OpaquePointer?
        #expect(sqlite3_open(registryURL.path, &database) == SQLITE_OK)
        let lockedDatabase = try #require(database)
        defer { sqlite3_close(lockedDatabase) }
        #expect(sqlite3_exec(lockedDatabase, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) }

        let didHibernate = await fixture.workspace.enterAgentHibernation(
            panelId: fixture.panelID,
            agent: fixture.agent,
            lastActivityAt: Date(timeIntervalSince1970: 10),
            finalValidation: { true }
        )

        #expect(!didHibernate)
        #expect(!fixture.panel.isAgentHibernated)
        #expect(fixture.panel.surface.surface == runtimeSurface)
        #expect(!nativeFreeCalled.loadAcquire())
        #expect(fixture.panel.surface.debugPendingSocketInputForTesting().items == 0)
        let saved = try fixture.registry.snapshot(provider: "codex")
        let savedRecord = try #require(saved.records.first)
        let savedObject = try #require(
            JSONSerialization.jsonObject(with: savedRecord.json) as? [String: Any]
        )
        #expect(savedObject["sessionState"] as? String == "active")

        fixture.panel.surface.teardownSurface()
        await cleanupFinished.waitUntilOpen()
    }

    @MainActor
    @Test func liveHibernationSnapshotCarriesCanonicalAuthorityGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-live-hibernation-generation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let runtimeID = "live-hibernation-generation-runtime"
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": runtimeID,
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeLiveHibernationAuthorityFixture(
            root: root,
            runtimeID: runtimeID,
            sessionID: "live-hibernation-generation-session"
        )
        let runtimeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        fixture.panel.surface.installRuntimeSurfaceForTesting(runtimeSurface)
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { pointer in
            pointer.deallocate()
        }
        defer { TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil }

        #expect(await fixture.workspace.enterAgentHibernation(
            panelId: fixture.panelID,
            agent: fixture.agent,
            lastActivityAt: Date(timeIntervalSince1970: 10),
            finalValidation: { true }
        ))
        #expect(fixture.panel.isAgentHibernated)

        let panelSnapshot = try #require(
            fixture.workspace.sessionSnapshot(includeScrollback: false).panels.first {
                $0.id == fixture.panelID
            }
        )
        let hibernatedAt = try #require(panelSnapshot.terminal?.hibernation?.hibernatedAt)
        let registrySnapshot = try fixture.registry.snapshot(provider: "codex")
        let canonicalRecord = try #require(registrySnapshot.records.first)
        let canonicalObject = try #require(
            JSONSerialization.jsonObject(with: canonicalRecord.json) as? [String: Any]
        )
        let canonicalUpdatedAt = try #require(canonicalObject["updatedAt"] as? TimeInterval)

        #expect(hibernatedAt.bitPattern == canonicalRecord.updatedAt.bitPattern)
        #expect(hibernatedAt.bitPattern == canonicalUpdatedAt.bitPattern)
    }

    @MainActor
    @Test func transientRegistryContentionKeepsManualResumeRetryable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-resume-contention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "resume-contention-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(root: root, sessionID: "resume-contention-session")
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

        let restored = Workspace()
        let mapping = restored.restoreSessionSnapshot(fixture.snapshot)
        let panelID = try #require(mapping[fixture.sourcePanelID])
        let panel = try #require(restored.terminalPanel(for: panelID))
        #expect(panel.isAgentHibernated)

        var database: OpaquePointer?
        #expect(sqlite3_open(registryURL.path, &database) == SQLITE_OK)
        let lockedDatabase = try #require(database)
        defer { sqlite3_close(lockedDatabase) }
        #expect(sqlite3_exec(lockedDatabase, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) }

        #expect(!restored.resumeAgentHibernation(panelId: panelID, focus: false))
        #expect(panel.isAgentHibernated)
        #expect(restored.restoredAgentSnapshotForTesting(panelId: panelID)?.sessionId == fixture.agent.sessionId)
        #expect(!panel.surface.debugInitialInputMetadata().hasInitialInput)
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 0)
    }

    @MainActor
    @Test func backgroundAdoptionCannotResumeAfterForeignTakeoverBeforeVisibility() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-hibernation-late-takeover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "late-takeover-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(
            root: root,
            sessionID: "late-takeover-session"
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

        let restored = Workspace()
        let mapping = restored.restoreSessionSnapshot(fixture.snapshot)
        let restoredPanelID = try #require(mapping[fixture.sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        #expect(restoredPanel.isAgentHibernated)

        let foreignWorkspaceID = UUID().uuidString
        let foreignSurfaceID = UUID().uuidString
        let takeoverAt = Date().timeIntervalSince1970
        let foreignRecord: [String: Any] = [
            "sessionId": fixture.agent.sessionId,
            "workspaceId": foreignWorkspaceID,
            "surfaceId": foreignSurfaceID,
            "sessionState": "active",
            "restoreAuthority": true,
            "startedAt": 10.0,
            "updatedAt": takeoverAt,
        ]
        let foreignSlot = try JSONSerialization.data(withJSONObject: [
            "sessionId": fixture.agent.sessionId,
            "updatedAt": takeoverAt,
        ], options: [.sortedKeys])
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        try registry.apply(
            provider: "codex",
            records: [.init(
                provider: "codex",
                sessionID: fixture.agent.sessionId,
                updatedAt: takeoverAt,
                json: try JSONSerialization.data(withJSONObject: foreignRecord, options: [.sortedKeys])
            )],
            activeSlots: [
                .init(
                    provider: "codex",
                    scope: .workspace,
                    scopeID: foreignWorkspaceID,
                    sessionID: fixture.agent.sessionId,
                    updatedAt: takeoverAt,
                    json: foreignSlot
                ),
                .init(
                    provider: "codex",
                    scope: .surface,
                    scopeID: foreignSurfaceID,
                    sessionID: fixture.agent.sessionId,
                    updatedAt: takeoverAt,
                    json: foreignSlot
                ),
            ],
            deletedSlots: [
                CmuxAgentSessionRegistry.slotKey(scope: .workspace, scopeID: restored.id.uuidString),
                CmuxAgentSessionRegistry.slotKey(scope: .surface, scopeID: restoredPanelID.uuidString),
            ]
        )

        restored.setAgentHibernationAutoResumePresentationVisible(true)

        #expect(!restoredPanel.isAgentHibernated)
        #expect(restored.restoredAgentSnapshotForTesting(panelId: restoredPanelID) == nil)
        #expect(!restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
        #expect(restoredPanel.surface.debugPendingSocketInputForTesting().items == 0)
        let snapshot = try registry.snapshot(provider: "codex")
        let record = try #require(snapshot.records.first)
        let object = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])
        #expect(object["workspaceId"] as? String == foreignWorkspaceID)
        #expect(object["surfaceId"] as? String == foreignSurfaceID)
        #expect(object["sessionState"] as? String == "active")
        #expect(Set(snapshot.activeSlots.map(\.scopeID)) == [foreignWorkspaceID, foreignSurfaceID])
    }

    @MainActor
    @Test func sameBindingForeignRuntimeCannotResumeRestoredAgent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-foreign-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let currentRuntime = "same-binding-current-runtime"
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": currentRuntime,
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(root: root, sessionID: "same-binding-session")
        let initialSlot: [String: Any] = [
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
            "activeSessionsByWorkspace": [fixture.source.id.uuidString: initialSlot],
            "activeSessionsBySurface": [fixture.sourcePanelID.uuidString: initialSlot],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"),
            options: .atomic
        )

        let restored = Workspace()
        let mapping = restored.restoreSessionSnapshot(fixture.snapshot)
        let restoredPanelID = try #require(mapping[fixture.sourcePanelID])
        let panel = try #require(restored.terminalPanel(for: restoredPanelID))
        #expect(panel.isAgentHibernated)

        let foreignRuntime: [String: Any] = ["id": "foreign-runtime"]
        let takeoverAt = Date().timeIntervalSince1970 + 100
        let foreignRecord: [String: Any] = [
            "sessionId": fixture.agent.sessionId,
            "workspaceId": restored.id.uuidString,
            "surfaceId": restoredPanelID.uuidString,
            "sessionState": "hibernated",
            "restoreAuthority": true,
            "activeRunId": "foreign-run",
            "cmuxRuntime": foreignRuntime,
            "runs": [[
                "runId": "foreign-run",
                "restoreAuthority": true,
                "cmuxRuntime": foreignRuntime,
                "startedAt": 10.0,
                "updatedAt": takeoverAt,
            ]],
            "startedAt": 10.0,
            "updatedAt": takeoverAt,
        ]
        let foreignSlot = try JSONSerialization.data(withJSONObject: [
            "sessionId": fixture.agent.sessionId,
            "updatedAt": takeoverAt,
        ], options: [.sortedKeys])
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        try registry.apply(
            provider: "codex",
            records: [.init(
                provider: "codex",
                sessionID: fixture.agent.sessionId,
                updatedAt: takeoverAt,
                json: try JSONSerialization.data(withJSONObject: foreignRecord, options: [.sortedKeys])
            )],
            activeSlots: [
                .init(
                    provider: "codex",
                    scope: .workspace,
                    scopeID: restored.id.uuidString,
                    sessionID: fixture.agent.sessionId,
                    updatedAt: takeoverAt,
                    json: foreignSlot
                ),
                .init(
                    provider: "codex",
                    scope: .surface,
                    scopeID: restoredPanelID.uuidString,
                    sessionID: fixture.agent.sessionId,
                    updatedAt: takeoverAt,
                    json: foreignSlot
                ),
            ]
        )

        restored.setAgentHibernationAutoResumePresentationVisible(true)

        #expect(!panel.isAgentHibernated)
        #expect(restored.restoredAgentSnapshotForTesting(panelId: restoredPanelID) == nil)
        #expect(!panel.surface.debugInitialInputMetadata().hasInitialInput)
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 0)
        let snapshot = try registry.snapshot(provider: "codex")
        let record = try #require(snapshot.records.first)
        let object = try #require(JSONSerialization.jsonObject(with: record.json) as? [String: Any])
        #expect(object["sessionState"] as? String == "hibernated")
        #expect((object["cmuxRuntime"] as? [String: Any])?["id"] as? String == "foreign-runtime")
        let runs = try #require(object["runs"] as? [[String: Any]])
        #expect((runs.first?["cmuxRuntime"] as? [String: Any])?["id"] as? String == "foreign-runtime")
        #expect(Set(snapshot.activeSlots.map(\.scopeID)) == [
            restored.id.uuidString,
            restoredPanelID.uuidString,
        ])
    }

    @MainActor
    @Test(arguments: ["current-owned-same", "foreign-owned-same", "foreign-distinct"])
    func preAdoptionForeignRuntimeRequiresADistinctLiveSocket(
        ownershipCase: String
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pre-adoption-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let liveSocketPath = NSTemporaryDirectory() + "cmux-owner-\(suffix).sock"
        let foreignRecordUsesCurrentSocket = ownershipCase != "foreign-distinct"
        let currentListenerOwnsPath = ownershipCase == "current-owned-same"
        let currentSocketPath = foreignRecordUsesCurrentSocket
            ? liveSocketPath
            : NSTemporaryDirectory() + "cmux-current-\(suffix).sock"
        let listener = try makeListeningUnixSocket(at: liveSocketPath)
        defer {
            Darwin.close(listener)
            unlink(liveSocketPath)
        }
        let environment = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "new-runtime",
            "CMUX_SOCKET_PATH": currentSocketPath,
            "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            "CMUX_BUNDLE_ID": "com.cmuxterm.app.debug.restore-runtime-test",
        ]

        let fixture = try makeHibernatedRestoreFixture(
            root: root,
            sessionID: "pre-adoption-\(ownershipCase)"
        )
        let registry = try installHibernatedAuthority(
            root: root,
            registryURL: registryURL,
            agent: fixture.agent,
            workspaceId: fixture.source.id,
            surfaceId: fixture.sourcePanelID,
            runtime: [
                "id": "old-runtime",
                "socketPath": liveSocketPath,
            ]
        )
        let targetWorkspaceId = UUID()
        let targetSurfaceId = UUID()
        let writer = AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: environment,
            currentSocketStateResolver: { preferredPath in
                (
                    activePath: currentSocketPath,
                    pathOwnedByCurrentListener: currentListenerOwnsPath
                        && SocketControlSettings.pathsMatch(preferredPath, currentSocketPath)
                )
            }
        )
        let adopted = writer.recordRestoredHibernationSynchronously(
            kind: .codex,
            sessionId: fixture.agent.sessionId,
            previousWorkspaceId: fixture.source.id.uuidString,
            previousSurfaceId: fixture.sourcePanelID.uuidString,
            workspaceId: targetWorkspaceId.uuidString,
            surfaceId: targetSurfaceId.uuidString,
            now: 30
        )
        let snapshot = try registry.snapshot(provider: "codex")
        let stored = try #require(snapshot.records.first)
        let object = try #require(JSONSerialization.jsonObject(with: stored.json) as? [String: Any])

        if currentListenerOwnsPath {
            #expect(adopted)
            #expect(object["workspaceId"] as? String == targetWorkspaceId.uuidString)
            #expect(object["surfaceId"] as? String == targetSurfaceId.uuidString)
            #expect((object["cmuxRuntime"] as? [String: Any])?["id"] as? String == "new-runtime")
        } else {
            #expect(!adopted)
            #expect(object["workspaceId"] as? String == fixture.source.id.uuidString)
            #expect(object["surfaceId"] as? String == fixture.sourcePanelID.uuidString)
            #expect((object["cmuxRuntime"] as? [String: Any])?["id"] as? String == "old-runtime")
        }
    }

    @MainActor
    @Test(arguments: [true, false])
    func preAdoptionForeignRuntimeUsesProcessGenerationWhenSocketIsUnavailable(
        foreignProcessIsLive: Bool
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pre-adoption-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let currentIdentity = try #require(AgentPIDProcessIdentity(pid: getpid()))
        let environment = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "new-runtime",
        ]
        let fixture = try makeHibernatedRestoreFixture(
            root: root,
            sessionID: foreignProcessIsLive ? "live-process-owner" : "recycled-process-owner"
        )
        let foreignRuntime: [String: Any] = [
            "id": "old-runtime",
            "processId": Int(currentIdentity.pid),
            "processStartSeconds": foreignProcessIsLive
                ? currentIdentity.startSeconds
                : currentIdentity.startSeconds - 1,
            "processStartMicroseconds": currentIdentity.startMicroseconds,
        ]
        let registry = try installHibernatedAuthority(
            root: root,
            registryURL: registryURL,
            agent: fixture.agent,
            workspaceId: fixture.source.id,
            surfaceId: fixture.sourcePanelID,
            runtime: foreignRuntime
        )
        let targetWorkspaceId = UUID()
        let targetSurfaceId = UUID()
        let writer = AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: environment
        )

        let adopted = writer.recordRestoredHibernationSynchronously(
            kind: .codex,
            sessionId: fixture.agent.sessionId,
            previousWorkspaceId: fixture.source.id.uuidString,
            previousSurfaceId: fixture.sourcePanelID.uuidString,
            workspaceId: targetWorkspaceId.uuidString,
            surfaceId: targetSurfaceId.uuidString,
            now: 30
        )
        let snapshot = try registry.snapshot(provider: "codex")
        let stored = try #require(snapshot.records.first)
        let object = try #require(JSONSerialization.jsonObject(with: stored.json) as? [String: Any])

        #expect(adopted == !foreignProcessIsLive)
        #expect(object["workspaceId"] as? String == (
            foreignProcessIsLive ? fixture.source.id.uuidString : targetWorkspaceId.uuidString
        ))
        #expect(object["surfaceId"] as? String == (
            foreignProcessIsLive ? fixture.sourcePanelID.uuidString : targetSurfaceId.uuidString
        ))
    }

    @MainActor
    @Test(arguments: [true, false])
    func currentListenerOwnershipUsesConfiguredAndOverrideSocketPaths(
        usesEnvironmentOverride: Bool
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-current-socket-resolution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let bundleId = "com.cmuxterm.app.debug.restore-socket-resolution"
        var environment = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "configured-new-runtime",
            "CMUX_BUNDLE_ID": bundleId,
            "CMUX_TAG": "rscfg",
        ]
        if usesEnvironmentOverride {
            environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-restore-override-\(UUID().uuidString).sock"
            environment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        }
        let expectedSocketPath = SocketControlSettings.socketPath(
            environment: environment,
            bundleIdentifier: bundleId
        )
        let fixture = try makeHibernatedRestoreFixture(
            root: root,
            sessionID: usesEnvironmentOverride
                ? "override-current-socket"
                : "configured-current-socket"
        )
        let registry = try installHibernatedAuthority(
            root: root,
            registryURL: registryURL,
            agent: fixture.agent,
            workspaceId: fixture.source.id,
            surfaceId: fixture.sourcePanelID,
            runtime: [
                "id": "configured-old-runtime",
                "socketPath": expectedSocketPath,
            ]
        )
        let targetWorkspaceId = UUID()
        let targetSurfaceId = UUID()
        let writer = AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: environment,
            currentSocketStateResolver: { preferredPath in
                (
                    activePath: expectedSocketPath,
                    pathOwnedByCurrentListener: SocketControlSettings.pathsMatch(
                        preferredPath,
                        expectedSocketPath
                    )
                )
            }
        )

        #expect(writer.recordRestoredHibernationSynchronously(
            kind: .codex,
            sessionId: fixture.agent.sessionId,
            previousWorkspaceId: fixture.source.id.uuidString,
            previousSurfaceId: fixture.sourcePanelID.uuidString,
            workspaceId: targetWorkspaceId.uuidString,
            surfaceId: targetSurfaceId.uuidString,
            now: 30
        ))
        let snapshot = try registry.snapshot(provider: "codex")
        let stored = try #require(snapshot.records.first)
        let object = try #require(JSONSerialization.jsonObject(with: stored.json) as? [String: Any])
        #expect(object["workspaceId"] as? String == targetWorkspaceId.uuidString)
        #expect(object["surfaceId"] as? String == targetSurfaceId.uuidString)
        #expect((object["cmuxRuntime"] as? [String: Any])?["id"] as? String == "configured-new-runtime")
    }

    @MainActor
    @Test func resumeAuthorityClaimSurvivesWallClockRollback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hibernation-clock-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let runtimeID = "clock-rollback-runtime"
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": runtimeID,
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "clock-rollback-session"
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
                capturedAt: 400,
                source: "agent-hook"
            )
        )
        let record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": workspaceID.uuidString,
            "surfaceId": surfaceID.uuidString,
            "sessionState": "hibernated",
            "restoreAuthority": true,
            "cmuxRuntime": ["id": runtimeID],
            "startedAt": 400.0,
            "updatedAt": 500.0,
        ]
        let slot = try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionID,
            "updatedAt": 500.0,
        ], options: [.sortedKeys])
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        try registry.apply(
            provider: "codex",
            records: [.init(
                provider: "codex",
                sessionID: sessionID,
                updatedAt: 500,
                json: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            )],
            activeSlots: [.init(
                provider: "codex",
                scope: .surface,
                scopeID: surfaceID.uuidString,
                sessionID: sessionID,
                updatedAt: 500,
                json: slot
            )]
        )

        #expect(AgentHookSessionStateWriter.acquireHibernatedResumeAuthority(
            agent: agent,
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            now: 100
        ) == .acquired)

        let snapshot = try registry.snapshot(provider: "codex")
        let saved = try #require(snapshot.records.first)
        let object = try #require(JSONSerialization.jsonObject(with: saved.json) as? [String: Any])
        let savedSlot = try #require(snapshot.activeSlots.first)
        let slotObject = try #require(JSONSerialization.jsonObject(with: savedSlot.json) as? [String: Any])
        #expect(object["sessionState"] as? String == "restoring")
        #expect(saved.updatedAt == 500)
        #expect(object["updatedAt"] as? TimeInterval == 500)
        #expect(savedSlot.updatedAt == 500)
        #expect(slotObject["updatedAt"] as? TimeInterval == 500)
    }

    @MainActor
    @Test func windowRestoreBatchesManyContendedWorkspacesIntoOneAdoptionOperation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-many-workspaces-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "many-workspaces-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let workspaceCount = 32
        let fixtures = try (0..<workspaceCount).map { index in
            try makeHibernatedRestoreFixture(root: root, sessionID: "batched-\(index)")
        }
        _ = try CmuxAgentSessionRegistry(url: registryURL).snapshot(provider: "codex")
        var database: OpaquePointer?
        #expect(sqlite3_open(registryURL.path, &database) == SQLITE_OK)
        let writer = try #require(database)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }

        var observedRequestCount = 0
        let adoptionBatch = RestoredAgentHibernationAdoptionBatch { requests in
            observedRequestCount = requests.count
            return AgentHookSessionStateWriter.recordRestoredHibernationOutcomes(requests)
        }
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: fixtures.map(\.snapshot)
        )

        _ = manager.restoreSessionSnapshot(
            snapshot,
            restoredAgentHibernationAdoptionBatch: adoptionBatch
        )

        #expect(adoptionBatch.adoptionOperationCount == 1)
        #expect(observedRequestCount == workspaceCount)
        #expect(manager.tabs.count == workspaceCount)
        #expect(manager.tabs.allSatisfy { workspace in
            guard let panelID = workspace.focusedPanelId,
                  let panel = workspace.terminalPanel(for: panelID) else { return false }
            return panel.isAgentHibernated
                && !panel.surface.debugInitialInputMetadata().hasInitialInput
                && panel.surface.debugPendingSocketInputForTesting().items == 0
        })
    }

    @MainActor
    @Test func visibleResumeBatchUsesOneClaimOperationDuringContention() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-visible-resume-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "visible-resume-batch-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let panelCount = 16
        let source = Workspace(workingDirectory: root.path)
        let firstPanelID = try #require(source.focusedPanelId)
        let paneID = try #require(source.paneId(forPanelId: firstPanelID))
        while source.panels.count < panelCount {
            _ = try #require(source.newTerminalSurface(inPane: paneID, focus: false))
        }
        var workspaceSnapshot = source.sessionSnapshot(includeScrollback: false)
        var sessions: [String: Any] = [:]
        var surfaceSlots: [String: Any] = [:]
        var firstSessionID: String?
        for index in workspaceSnapshot.panels.indices {
            let panelID = workspaceSnapshot.panels[index].id
            let sessionID = "visible-batch-\(index)"
            if firstSessionID == nil { firstSessionID = sessionID }
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
            var terminal = try #require(workspaceSnapshot.panels[index].terminal)
            terminal.agent = agent
            terminal.resumeBinding = SurfaceResumeBindingSnapshot(
                kind: agent.kind.rawValue,
                command: try #require(agent.resumeCommand),
                cwd: root.path,
                checkpointId: sessionID,
                source: "agent-hook",
                autoResume: false,
                updatedAt: 20
            )
            terminal.hibernation = SessionAgentHibernationSnapshot(
                hibernatedAt: 20,
                lastActivityAt: 10
            )
            workspaceSnapshot.panels[index].terminal = terminal
            sessions[sessionID] = [
                "sessionId": sessionID,
                "workspaceId": source.id.uuidString,
                "surfaceId": panelID.uuidString,
                "sessionState": "hibernated",
                "restoreAuthority": true,
                "startedAt": 10.0,
                "updatedAt": 20.0,
            ]
            surfaceSlots[panelID.uuidString] = [
                "sessionId": sessionID,
                "updatedAt": 20.0,
            ]
        }
        let workspaceOwner = try #require(firstSessionID)
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": sessions,
            "activeSessionsByWorkspace": [source.id.uuidString: [
                "sessionId": workspaceOwner,
                "updatedAt": 20.0,
            ]],
            "activeSessionsBySurface": surfaceSlots,
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"),
            options: .atomic
        )

        let restored = Workspace()
        let mapping = restored.restoreSessionSnapshot(workspaceSnapshot)
        let restoredPanelIDs = Set(mapping.values)
        #expect(restoredPanelIDs.count == panelCount)
        #expect(restoredPanelIDs.allSatisfy {
            restored.terminalPanel(for: $0)?.isAgentHibernated == true
        })

        var database: OpaquePointer?
        #expect(sqlite3_open(registryURL.path, &database) == SQLITE_OK)
        let lockedDatabase = try #require(database)
        defer { sqlite3_close(lockedDatabase) }
        #expect(sqlite3_exec(lockedDatabase, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(lockedDatabase, "ROLLBACK", nil, nil, nil) }

        var claimOperationCount = 0
        var observedRequestCount = 0
        let didResume = restored.resumeVisibleAgentHibernationPanels(
            panelIds: restoredPanelIDs,
            authorityClaimHandler: { requests in
                claimOperationCount += 1
                observedRequestCount = requests.count
                return AgentHookSessionStateWriter.acquireHibernatedResumeAuthorities(requests)
            }
        )

        #expect(!didResume)
        #expect(claimOperationCount == 1)
        #expect(observedRequestCount == panelCount)
        #expect(restoredPanelIDs.allSatisfy {
            restored.terminalPanel(for: $0)?.isAgentHibernated == true
        })
        #expect(restoredPanelIDs.allSatisfy {
            restored.terminalPanel(for: $0)?.surface.debugInitialInputMetadata().hasInitialInput == false
        })
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
        let rejectedRecord = try #require(registrySnapshot.records.first)
        let rejectedObject = try #require(
            JSONSerialization.jsonObject(with: rejectedRecord.json) as? [String: Any]
        )
        #expect(rejectedObject["sessionState"] == nil)
        #expect(registrySnapshot.activeSlots.isEmpty)
    }

    @MainActor
    @Test func failedRestorePreflightDiscardsAllRestorableHibernationsInOneBatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-hibernation-preflight-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeHibernatedRestoreFixture(
            root: root,
            sessionID: "preflight-batch-session"
        )
        var sourcePanel = try #require(
            fixture.snapshot.panels.first { $0.id == fixture.sourcePanelID }
        )
        var sourceTerminal = try #require(sourcePanel.terminal)
        var sourceAgent = try #require(sourceTerminal.agent)
        sourceAgent.kind = .custom("pi")
        sourceTerminal.agent = sourceAgent
        sourcePanel.terminal = sourceTerminal
        var workspace = fixture.snapshot
        workspace.panels = (0..<SessionPersistencePolicy.maxPanelsPerWorkspace).map { _ in
            var panel = sourcePanel
            panel.id = UUID()
            return panel
        }
        var snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 20,
            windows: [SessionWindowSnapshot(
                windowId: UUID(),
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(
                    selectedWorkspaceIndex: 0,
                    workspaces: [workspace]
                ),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )]
        )
        let environment = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root
                .appendingPathComponent(CmuxAgentSessionRegistry.filename)
                .path,
        ]
        var failedKinds = Set<RestorableAgentKind>()

        let elapsed = ContinuousClock().measure {
            failedKinds = RestorableAgentSessionIndex.prepareAgentRegistryForSessionRestore(
                &snapshot,
                homeDirectory: root.path,
                environment: environment
            )
        }

        #expect(elapsed < .seconds(1))
        #expect(failedKinds == [.pi])
        let terminals = snapshot.windows[0].tabManager.workspaces[0].panels.compactMap(\.terminal)
        #expect(terminals.count == SessionPersistencePolicy.maxPanelsPerWorkspace)
        #expect(terminals.allSatisfy {
            $0.agent == nil &&
                $0.hibernation == nil &&
                $0.resumeBinding == nil &&
                $0.wasAgentRunning == false
        })
    }

    @MainActor
    @Test func malformedChangedLegacySidecarPreservesOnlyExactCanonicalHibernationAndRetriesRewrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-hibernation-corrupt-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let canonicalSessionID = "canonical-hibernation"
        let legacySessionID = "legacy-only-hibernation"
        let fixture = try makeHibernatedRestoreFixture(
            root: root,
            sessionID: canonicalSessionID
        )
        var workspace = fixture.snapshot
        var legacyPanel = try #require(
            workspace.panels.first { $0.id == fixture.sourcePanelID }
        )
        legacyPanel.id = UUID()
        var legacyTerminal = try #require(legacyPanel.terminal)
        var legacyAgent = try #require(legacyTerminal.agent)
        legacyAgent.sessionId = legacySessionID
        legacyTerminal.agent = legacyAgent
        var legacyBinding = try #require(legacyTerminal.resumeBinding)
        legacyBinding.checkpointId = legacySessionID
        legacyTerminal.resumeBinding = legacyBinding
        legacyPanel.terminal = legacyTerminal
        workspace.panels.append(legacyPanel)

        let workspaceID = fixture.source.id.uuidString
        func record(sessionID: String, surfaceID: UUID) -> [String: Any] {
            [
                "sessionId": sessionID,
                "workspaceId": workspaceID,
                "surfaceId": surfaceID.uuidString,
                "sessionState": "hibernated",
                "restoreAuthority": true,
                "startedAt": 10.0,
                "updatedAt": 20.0,
            ]
        }
        func slot(sessionID: String) -> [String: Any] {
            ["sessionId": sessionID, "updatedAt": 20.0]
        }
        func legacyStoreData() throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "version": 2,
                "sessions": [
                    canonicalSessionID: record(
                        sessionID: canonicalSessionID,
                        surfaceID: fixture.sourcePanelID
                    ),
                    legacySessionID: record(
                        sessionID: legacySessionID,
                        surfaceID: legacyPanel.id
                    ),
                ],
                "activeSessionsBySurface": [
                    fixture.sourcePanelID.uuidString: slot(sessionID: canonicalSessionID),
                    legacyPanel.id.uuidString: slot(sessionID: legacySessionID),
                ],
            ], options: [.sortedKeys])
        }

        try legacyStoreData().write(to: stateURL, options: .atomic)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        _ = try registry.snapshotImportingLegacy(
            provider: "codex",
            legacyURL: stateURL
        )
        let canonicalSlotJSON = try JSONSerialization.data(
            withJSONObject: slot(sessionID: canonicalSessionID),
            options: [.sortedKeys]
        )
        try registry.apply(
            provider: "codex",
            records: [.init(
                provider: "codex",
                sessionID: canonicalSessionID,
                updatedAt: 20,
                json: try JSONSerialization.data(
                    withJSONObject: record(
                        sessionID: canonicalSessionID,
                        surfaceID: fixture.sourcePanelID
                    ),
                    options: [.sortedKeys]
                )
            )],
            activeSlots: [.init(
                provider: "codex",
                scope: .surface,
                scopeID: fixture.sourcePanelID.uuidString,
                sessionID: canonicalSessionID,
                updatedAt: 20,
                json: canonicalSlotJSON
            )]
        )
        try Data("{broken".utf8).write(to: stateURL, options: .atomic)

        let persistedSnapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 20,
            windows: [SessionWindowSnapshot(
                windowId: UUID(),
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(
                    selectedWorkspaceIndex: 0,
                    workspaces: [workspace]
                ),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )]
        )
        let environment = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
        ]
        func restoredSessionIDs(_ snapshot: AppSessionSnapshot) -> Set<String> {
            Set(snapshot.windows[0].tabManager.workspaces[0].panels.compactMap {
                $0.terminal?.hibernation == nil ? nil : $0.terminal?.agent?.sessionId
            })
        }

        var corruptSnapshot = persistedSnapshot
        let failedKinds = RestorableAgentSessionIndex.prepareAgentRegistryForSessionRestore(
            &corruptSnapshot,
            homeDirectory: root.path,
            environment: environment
        )

        #expect(failedKinds == [.codex])
        #expect(restoredSessionIDs(corruptSnapshot) == [canonicalSessionID])
        let afterCorruption = try registry.records(
            provider: "codex",
            sessionIDs: [canonicalSessionID]
        )
        #expect(afterCorruption.first?.writerGeneration == CmuxAgentSessionRegistry.currentWriterGeneration)
        let expectedCanonicalJSON = try JSONSerialization.data(
            withJSONObject: record(
                sessionID: canonicalSessionID,
                surfaceID: fixture.sourcePanelID
            ),
            options: [.sortedKeys]
        )
        #expect(afterCorruption.first?.json == expectedCanonicalJSON)

        var repeatedCorruptSnapshot = persistedSnapshot
        let repeatedFailures = RestorableAgentSessionIndex.prepareAgentRegistryForSessionRestore(
            &repeatedCorruptSnapshot,
            homeDirectory: root.path,
            environment: environment
        )
        #expect(repeatedFailures == [.codex])
        #expect(restoredSessionIDs(repeatedCorruptSnapshot) == [canonicalSessionID])

        try legacyStoreData().write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 40)],
            ofItemAtPath: stateURL.path
        )
        var repairedSnapshot = persistedSnapshot
        let retriedFailures = RestorableAgentSessionIndex.prepareAgentRegistryForSessionRestore(
            &repairedSnapshot,
            homeDirectory: root.path,
            environment: environment
        )

        #expect(retriedFailures.isEmpty)
        #expect(restoredSessionIDs(repairedSnapshot) == [canonicalSessionID, legacySessionID])
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

    @Test func hibernationTracksTheActualListenerSocketAcrossRebinds() throws {
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

        let firstSocketPath = "/tmp/cmux-current-first-\(UUID().uuidString).sock"
        AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_RUNTIME_ID": "current-runtime",
                "CMUX_BUNDLE_ID": "com.cmuxterm.current",
            ],
            currentSocketStateResolver: { _ in
                (activePath: firstSocketPath, pathOwnedByCurrentListener: true)
            }
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
        #expect(recordRuntime["socketPath"] as? String == firstSocketPath)
        let runs = try #require(record["runs"] as? [[String: Any]])
        let runRuntime = try #require(runs.first?["cmuxRuntime"] as? [String: Any])
        #expect(runRuntime["id"] as? String == "current-runtime")
        #expect(runRuntime["socketPath"] as? String == firstSocketPath)

        let reboundSocketPath = "/tmp/cmux-current-rebound-\(UUID().uuidString).sock"
        AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_RUNTIME_ID": "current-runtime",
                "CMUX_BUNDLE_ID": "com.cmuxterm.current",
            ],
            currentSocketStateResolver: { _ in
                (activePath: reboundSocketPath, pathOwnedByCurrentListener: true)
            }
        ).setLifecycleSynchronously(
            kind: .codex,
            sessionId: "session",
            state: .restoring,
            now: 201
        )

        let reboundRoot = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let reboundSessions = try #require(reboundRoot["sessions"] as? [String: Any])
        let reboundRecord = try #require(reboundSessions["session"] as? [String: Any])
        let reboundRuntime = try #require(reboundRecord["cmuxRuntime"] as? [String: Any])
        #expect(reboundRuntime["socketPath"] as? String == reboundSocketPath)
    }

    @MainActor
    @Test(arguments: ["clear", "evict"])
    func permanentlyDiscardedClosedHistoryReleasesHibernatedAuthority(
        removal: String
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-closed-history-release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "closed-history-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(
            root: root,
            sessionID: "closed-history-\(removal)"
        )
        let registry = try installHibernatedAuthority(
            root: root,
            registryURL: registryURL,
            agent: fixture.agent,
            workspaceId: fixture.source.id,
            surfaceId: fixture.sourcePanelID
        )
        let hibernatedPanel = try #require(
            fixture.snapshot.panels.first { $0.id == fixture.sourcePanelID }
        )
        let store = ClosedItemHistoryStore(capacity: removal == "evict" ? 1 : 2)
        store.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: fixture.source.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: hibernatedPanel
        )))

        if removal == "clear" {
            store.removeAll()
        } else {
            var replacementPanel = hibernatedPanel
            replacementPanel.id = UUID()
            replacementPanel.terminal?.agent = nil
            replacementPanel.terminal?.hibernation = nil
            store.push(.panel(ClosedPanelHistoryEntry(
                workspaceId: UUID(),
                paneId: UUID(),
                tabIndex: 0,
                snapshot: replacementPanel
            )))
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var registrySnapshot = try registry.snapshot(provider: "codex")
        while clock.now < deadline {
            guard let record = registrySnapshot.records.first,
                  let object = try JSONSerialization.jsonObject(with: record.json) as? [String: Any],
                  object["sessionState"] as? String != "ended" else {
                break
            }
            try await clock.sleep(for: .milliseconds(10))
            registrySnapshot = try registry.snapshot(provider: "codex")
        }

        let stored = try #require(registrySnapshot.records.first)
        let object = try #require(JSONSerialization.jsonObject(with: stored.json) as? [String: Any])
        #expect(object["sessionState"] as? String == "ended")
        #expect(object["restoreAuthority"] as? Bool == false)
        #expect(registrySnapshot.activeSlots.isEmpty)
    }

    @MainActor
    @Test(arguments: [false, true])
    func pendingClosedHistoryReleaseRetriesAfterRestartWithoutEndingAReusedSession(
        reusesSessionGeneration: Bool
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-closed-history-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "closed-history-restart-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        owner.arguments = ["30"]
        try owner.run()
        defer {
            if owner.isRunning {
                owner.terminate()
                owner.waitUntilExit()
            }
        }
        let ownerIdentity = try #require(AgentPIDProcessIdentity(pid: owner.processIdentifier))
        let foreignRuntime: [String: Any] = [
            "id": "foreign-live-runtime",
            "processId": Int(ownerIdentity.pid),
            "processStartSeconds": ownerIdentity.startSeconds,
            "processStartMicroseconds": ownerIdentity.startMicroseconds,
        ]
        let fixture = try makeHibernatedRestoreFixture(
            root: root,
            sessionID: reusesSessionGeneration
                ? "closed-history-reused-session"
                : "closed-history-retry-session"
        )
        let registry = try installHibernatedAuthority(
            root: root,
            registryURL: registryURL,
            agent: fixture.agent,
            workspaceId: fixture.source.id,
            surfaceId: fixture.sourcePanelID,
            runtime: foreignRuntime
        )
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let legacyLock = open(
            stateURL.path + ".lock",
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        let legacyLock = try #require(legacyLock >= 0 ? legacyLock : nil)
        defer { Darwin.close(legacyLock) }
        #expect(flock(legacyLock, LOCK_EX | LOCK_NB) == 0)
        var legacyLockIsHeld = true
        defer {
            if legacyLockIsHeld { _ = flock(legacyLock, LOCK_UN) }
        }

        let hibernatedPanel = try #require(
            fixture.snapshot.panels.first { $0.id == fixture.sourcePanelID }
        )
        let store = ClosedItemHistoryStore(capacity: 2)
        store.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: fixture.source.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: hibernatedPanel
        )))
        store.removeAll()

        let queueDirectory = root.appendingPathComponent(
            "pending-closed-history-releases-v1",
            isDirectory: true
        )
        func pendingReleaseURLs() -> [URL] {
            (try? FileManager.default.contentsOfDirectory(
                at: queueDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.filter { $0.pathExtension == "json" } ?? []
        }
        func hasArmedRelease() -> Bool {
            pendingReleaseURLs().contains { url in
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let requests = object["requests"] as? [[String: Any]] else {
                    return false
                }
                return requests.contains { $0["recordFingerprint"] is String }
            }
        }

        let clock = ContinuousClock()
        let armDeadline = clock.now.advanced(by: .seconds(2))
        while clock.now < armDeadline, !hasArmedRelease() {
            try await clock.sleep(for: .milliseconds(10))
        }
        #expect(hasArmedRelease())
        let liveOwnerSnapshot = try registry.snapshot(provider: "codex")
        let liveOwnerRecord = try #require(liveOwnerSnapshot.records.first)
        let liveOwnerObject = try #require(
            JSONSerialization.jsonObject(with: liveOwnerRecord.json) as? [String: Any]
        )
        #expect(liveOwnerObject["sessionState"] as? String == "hibernated")

        if reusesSessionGeneration {
            let replacementUpdatedAt = 40.0
            let replacementRecord: [String: Any] = [
                "sessionId": fixture.agent.sessionId,
                "workspaceId": fixture.source.id.uuidString,
                "surfaceId": fixture.sourcePanelID.uuidString,
                "sessionState": "active",
                "restoreAuthority": true,
                "startedAt": 30.0,
                "updatedAt": replacementUpdatedAt,
            ]
            let replacementSlot: [String: Any] = [
                "sessionId": fixture.agent.sessionId,
                "updatedAt": replacementUpdatedAt,
            ]
            let replacementSlotJSON = try JSONSerialization.data(
                withJSONObject: replacementSlot,
                options: [.sortedKeys]
            )
            try registry.apply(
                provider: "codex",
                records: [.init(
                    provider: "codex",
                    sessionID: fixture.agent.sessionId,
                    updatedAt: replacementUpdatedAt,
                    json: try JSONSerialization.data(
                        withJSONObject: replacementRecord,
                        options: [.sortedKeys]
                    )
                )],
                activeSlots: [
                    .init(
                        provider: "codex",
                        scope: .workspace,
                        scopeID: fixture.source.id.uuidString,
                        sessionID: fixture.agent.sessionId,
                        updatedAt: replacementUpdatedAt,
                        json: replacementSlotJSON
                    ),
                    .init(
                        provider: "codex",
                        scope: .surface,
                        scopeID: fixture.sourcePanelID.uuidString,
                        sessionID: fixture.agent.sessionId,
                        updatedAt: replacementUpdatedAt,
                        json: replacementSlotJSON
                    ),
                ]
            )
        }

        #expect(flock(legacyLock, LOCK_UN) == 0)
        legacyLockIsHeld = false
        owner.terminate()
        owner.waitUntilExit()
        AgentHookSessionStateWriter.resumePendingClosedHistoryHibernationReleases(now: 50)

        let releaseDeadline = clock.now.advanced(by: .seconds(2))
        var finalSnapshot = try registry.snapshot(provider: "codex")
        while clock.now < releaseDeadline {
            let object = try finalSnapshot.records.first.flatMap {
                try JSONSerialization.jsonObject(with: $0.json) as? [String: Any]
            }
            let reachedExpectedState = reusesSessionGeneration
                ? object?["sessionState"] as? String == "active"
                    && pendingReleaseURLs().isEmpty
                : object?["sessionState"] as? String == "ended"
            if reachedExpectedState { break }
            try await clock.sleep(for: .milliseconds(10))
            finalSnapshot = try registry.snapshot(provider: "codex")
        }

        let finalRecord = try #require(finalSnapshot.records.first)
        let finalObject = try #require(
            JSONSerialization.jsonObject(with: finalRecord.json) as? [String: Any]
        )
        if reusesSessionGeneration {
            #expect(finalObject["sessionState"] as? String == "active")
            #expect(finalObject["restoreAuthority"] as? Bool == true)
            #expect(finalSnapshot.activeSlots.count == 2)
        } else {
            #expect(finalObject["sessionState"] as? String == "ended")
            #expect(finalObject["restoreAuthority"] as? Bool == false)
            #expect(finalSnapshot.activeSlots.isEmpty)
        }
        #expect(pendingReleaseURLs().isEmpty)
    }

    @MainActor
    @Test func preparedReleaseDoesNotForfeitPersistedHistoryRouteAfterCrash() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-closed-history-prepared-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            "CMUX_RUNTIME_ID": "closed-history-crash-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        let fixture = try makeHibernatedRestoreFixture(
            root: root,
            sessionID: "closed-history-prepared-crash"
        )
        let registry = try installHibernatedAuthority(
            root: root,
            registryURL: registryURL,
            agent: fixture.agent,
            workspaceId: fixture.source.id,
            surfaceId: fixture.sourcePanelID
        )
        let hibernatedPanel = try #require(
            fixture.snapshot.panels.first { $0.id == fixture.sourcePanelID }
        )
        let historyRecord = ClosedItemHistoryRecord(entry: .panel(ClosedPanelHistoryEntry(
            workspaceId: fixture.source.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: hibernatedPanel
        )))
        let historyURL = root.appendingPathComponent("closed-item-history.json")
        let historyStore = ClosedItemHistoryStore(
            fileURL: historyURL,
            loadPersisted: false,
            persistsRecordsSynchronously: true
        )
        historyStore.push(historyRecord)
        #expect(FileManager.default.fileExists(atPath: historyURL.path))

        let crashedOwner = Process()
        crashedOwner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        crashedOwner.arguments = ["30"]
        try crashedOwner.run()
        let crashedOwnerIdentity = try #require(
            AgentPIDProcessIdentity(pid: crashedOwner.processIdentifier)
        )
        crashedOwner.terminate()
        crashedOwner.waitUntilExit()

        let queueDirectory = root.appendingPathComponent(
            "pending-closed-history-releases-v1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: queueDirectory,
            withIntermediateDirectories: true
        )
        let queueURL = queueDirectory.appendingPathComponent("prepared-crash.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "requests": [[
                "provider": "codex",
                "sessionId": fixture.agent.sessionId,
                "workspaceId": fixture.source.id.uuidString,
                "surfaceId": fixture.sourcePanelID.uuidString,
                "expectedRecordUpdatedAt": 20.0,
                "persistenceState": "prepared",
                "historyFilePath": historyURL.path,
                "historyRecordId": historyRecord.id.uuidString,
                "persistenceOwnerProcessId": Int(crashedOwnerIdentity.pid),
                "persistenceOwnerStartSeconds": crashedOwnerIdentity.startSeconds,
                "persistenceOwnerStartMicroseconds": crashedOwnerIdentity.startMicroseconds,
            ]],
        ], options: [.sortedKeys]).write(to: queueURL, options: .atomic)

        AgentHookSessionStateWriter.resumePendingClosedHistoryHibernationReleases(now: 50)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline, FileManager.default.fileExists(atPath: queueURL.path) {
            try await clock.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: queueURL.path))

        let registrySnapshot = try registry.snapshot(provider: "codex")
        let stored = try #require(registrySnapshot.records.first)
        let object = try #require(JSONSerialization.jsonObject(with: stored.json) as? [String: Any])
        #expect(object["sessionState"] as? String == "hibernated")
        #expect(object["restoreAuthority"] as? Bool == true)
        #expect(Set(registrySnapshot.activeSlots.map(\.scopeID)) == [
            fixture.source.id.uuidString,
            fixture.sourcePanelID.uuidString,
        ])
        let restoredHistory = ClosedItemHistoryStore(
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        #expect(restoredHistory.menuSnapshot().items.map(\.id) == [historyRecord.id])
    }

    @MainActor
    @Test func pendingReleaseStartupPassIsBoundedAndQuarantinesInvalidFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-closed-history-bounded-\(UUID().uuidString)", isDirectory: true)
        let queueDirectory = root.appendingPathComponent(
            "pending-closed-history-releases-v1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: queueDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let overrides = [
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root
                .appendingPathComponent(CmuxAgentSessionRegistry.filename).path,
            "CMUX_RUNTIME_ID": "closed-history-bounded-runtime",
        ]
        let previousEnvironment = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        for index in 0..<63 {
            try Data("{}".utf8).write(
                to: queueDirectory.appendingPathComponent("malformed-\(index).json"),
                options: .atomic
            )
        }
        try Data(repeating: 0, count: 512 * 1_024 + 1).write(
            to: queueDirectory.appendingPathComponent("oversized.json"),
            options: .atomic
        )
        let rawRequest: [String: Any] = [
            "provider": "codex",
            "sessionId": "too-many-entries",
            "workspaceId": UUID().uuidString,
            "surfaceId": UUID().uuidString,
            "expectedRecordUpdatedAt": 20.0,
            "recordFingerprint": NSNull(),
        ]
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "requests": Array(repeating: rawRequest, count: 513),
        ], options: [.sortedKeys]).write(
            to: queueDirectory.appendingPathComponent("too-many.json"),
            options: .atomic
        )

        func pendingJSONCount() -> Int {
            ((try? FileManager.default.contentsOfDirectory(
                at: queueDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.pathExtension == "json" }.count
        }
        let quarantineDirectory = queueDirectory.appendingPathComponent(
            "quarantine",
            isDirectory: true
        )
        func quarantinedCount() -> Int {
            ((try? FileManager.default.contentsOfDirectory(
                at: quarantineDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.pathExtension == "invalid" }.count
        }

        let schedulingElapsed = ContinuousClock().measure {
            AgentHookSessionStateWriter.resumePendingClosedHistoryHibernationReleases(now: 30)
        }
        #expect(schedulingElapsed < .milliseconds(100))
        let clock = ContinuousClock()
        let firstPassDeadline = clock.now.advanced(by: .seconds(5))
        while clock.now < firstPassDeadline, pendingJSONCount() > 1 {
            try await clock.sleep(for: .milliseconds(10))
        }
        #expect(pendingJSONCount() == 1)
        #expect((1...64).contains(quarantinedCount()))

        AgentHookSessionStateWriter.resumePendingClosedHistoryHibernationReleases(now: 31)
        let secondPassDeadline = clock.now.advanced(by: .seconds(2))
        while clock.now < secondPassDeadline, pendingJSONCount() != 0 {
            try await clock.sleep(for: .milliseconds(10))
        }
        #expect(pendingJSONCount() == 0)
        #expect((1...64).contains(quarantinedCount()))
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
            let storeURL = root.appendingPathComponent("\(provider)-hook-sessions.json")
            var sessions: [String: Any] = [:]
            if let existingData = try? Data(contentsOf: storeURL),
               let existingStore = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
               let existingSessions = existingStore["sessions"] as? [String: Any] {
                sessions = existingSessions
            }
            sessions[sessionId] = [
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
            ]
            let store: [String: Any] = [
                "version": 2,
                "sessions": sessions,
            ]
            try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
                .write(to: storeURL, options: .atomic)
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
            provider: "claude",
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
        #expect(lines.first?.hasPrefix("claude parent-session") == true, Comment(rawValue: result.stdout))
        #expect(lines.last?.hasPrefix("└── spawned claude child-session") == true, Comment(rawValue: result.stdout))
    }

    @MainActor
    private func makeLiveHibernationAuthorityFixture(
        root: URL,
        runtimeID: String,
        sessionID: String
    ) throws -> (
        workspace: Workspace,
        panelID: UUID,
        panel: TerminalPanel,
        agent: SessionRestorableAgentSnapshot,
        registry: CmuxAgentSessionRegistry
    ) {
        let workspace = Workspace(workingDirectory: root.path)
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))
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
        #expect(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: agent.kind.rawValue,
                command: try #require(agent.resumeCommand),
                cwd: root.path,
                checkpointId: sessionID,
                source: "agent-hook",
                autoResume: false,
                updatedAt: 20
            ),
            panelId: panelID
        ))
        let runtime: [String: Any] = ["id": runtimeID]
        let record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": workspace.id.uuidString,
            "surfaceId": panelID.uuidString,
            "sessionState": "active",
            "restoreAuthority": true,
            "activeRunId": "live-run",
            "cmuxRuntime": runtime,
            "runs": [[
                "runId": "live-run",
                "restoreAuthority": true,
                "cmuxRuntime": runtime,
                "startedAt": 10.0,
                "updatedAt": 20.0,
            ]],
            "startedAt": 10.0,
            "updatedAt": 20.0,
        ]
        let slotObject: [String: Any] = ["sessionId": sessionID, "updatedAt": 20.0]
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionID: record],
            "activeSessionsByWorkspace": [workspace.id.uuidString: slotObject],
            "activeSessionsBySurface": [panelID.uuidString: slotObject],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"),
            options: .atomic
        )
        let slotJSON = try JSONSerialization.data(withJSONObject: slotObject, options: [.sortedKeys])
        let registry = CmuxAgentSessionRegistry(
            url: root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        try registry.apply(
            provider: "codex",
            records: [.init(
                provider: "codex",
                sessionID: sessionID,
                updatedAt: 20,
                json: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            )],
            activeSlots: [
                .init(
                    provider: "codex",
                    scope: .workspace,
                    scopeID: workspace.id.uuidString,
                    sessionID: sessionID,
                    updatedAt: 20,
                    json: slotJSON
                ),
                .init(
                    provider: "codex",
                    scope: .surface,
                    scopeID: panelID.uuidString,
                    sessionID: sessionID,
                    updatedAt: 20,
                    json: slotJSON
                ),
            ]
        )
        return (workspace, panelID, panel, agent, registry)
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
        source.focusPanel(sourcePanelID)
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
        terminal.resumeBinding = SurfaceResumeBindingSnapshot(
            kind: agent.kind.rawValue,
            command: try #require(agent.resumeCommand),
            cwd: root.path,
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: false,
            updatedAt: 20
        )
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

    private func installHibernatedAuthority(
        root: URL,
        registryURL: URL,
        agent: SessionRestorableAgentSnapshot,
        workspaceId: UUID,
        surfaceId: UUID,
        runtime: [String: Any]? = nil
    ) throws -> CmuxAgentSessionRegistry {
        let activeSlot: [String: Any] = [
            "sessionId": agent.sessionId,
            "updatedAt": 20.0,
        ]
        var record: [String: Any] = [
            "sessionId": agent.sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": surfaceId.uuidString,
            "sessionState": "hibernated",
            "restoreAuthority": true,
            "startedAt": 10.0,
            "updatedAt": 20.0,
        ]
        if let runtime {
            record["activeRunId"] = "restored-run"
            record["cmuxRuntime"] = runtime
            record["runs"] = [[
                "runId": "restored-run",
                "restoreAuthority": true,
                "cmuxRuntime": runtime,
                "startedAt": 10.0,
                "updatedAt": 20.0,
            ]]
        }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [agent.sessionId: record],
            "activeSessionsByWorkspace": [workspaceId.uuidString: activeSlot],
            "activeSessionsBySurface": [surfaceId.uuidString: activeSlot],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        _ = try registry.snapshotImportingLegacy(
            provider: "codex",
            legacyURL: stateURL,
            fileManager: .default
        )
        return registry
    }

    private func makeListeningUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: "cmux.tests", code: Int(errno))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            Darwin.close(descriptor)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG))
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: bytes)
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 8) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw NSError(domain: "cmux.tests", code: Int(code))
        }
        return descriptor
    }

}

private actor AgentSessionAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilOpen() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
