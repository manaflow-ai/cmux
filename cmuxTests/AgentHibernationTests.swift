import Foundation
import XCTest
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentHibernationTests: XCTestCase {
    func testLifecycleStateParsingAcceptsShellFriendlyAliases() throws {
        XCTAssertEqual(AgentHibernationLifecycleState.parseCLIValue("IDLE"), .idle)
        XCTAssertEqual(AgentHibernationLifecycleState.parseCLIValue("needsInput"), .needsInput)
        XCTAssertEqual(AgentHibernationLifecycleState.parseCLIValue("needs-input"), .needsInput)
        XCTAssertEqual(AgentHibernationLifecycleState.parseCLIValue("needs_input"), .needsInput)
        XCTAssertNil(AgentHibernationLifecycleState.parseCLIValue("paused"))

        let decoded = try JSONDecoder().decode(
            AgentHibernationLifecycleState.self,
            from: Data(#""paused""#.utf8)
        )
        XCTAssertEqual(decoded, .unknown)
    }

    func testSettingsDefaultToOptInAndNotifyOnChanges() throws {
        let suiteName = "cmux-agent-hibernation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AgentHibernationSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(AgentHibernationSettings.idleSeconds(defaults: defaults), 3600)
        XCTAssertEqual(AgentHibernationSettings.maxLiveTerminals(defaults: defaults), 12)

        let notificationCenter = NotificationCenter()
        var notificationCount = 0
        let observer = notificationCenter.addObserver(
            forName: AgentHibernationSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { notificationCenter.removeObserver(observer) }

        AgentHibernationSettings.setValues(
            enabled: true,
            idleSeconds: 10,
            maxLiveTerminals: 4,
            defaults: defaults,
            notificationCenter: notificationCenter
        )

        let values = AgentHibernationSettings.values(defaults: defaults)
        XCTAssertTrue(values.enabled)
        XCTAssertEqual(values.idleSeconds, 10)
        XCTAssertEqual(values.maxLiveTerminals, 4)
        XCTAssertEqual(notificationCount, 1)

        defaults.set(42, forKey: AgentHibernationSettings.confirmationSecondsKey)
        XCTAssertEqual(AgentHibernationSettings.confirmationSeconds(defaults: defaults), 42)
        AgentHibernationSettings.reset(defaults: defaults, notificationCenter: notificationCenter)
        XCTAssertEqual(AgentHibernationSettings.confirmationSeconds(defaults: defaults), AgentHibernationSettings.defaultConfirmationSeconds)
        XCTAssertNil(defaults.object(forKey: AgentHibernationSettings.confirmationSecondsKey))
        XCTAssertEqual(notificationCount, 2)

        AgentHibernationSettings.setValues(
            enabled: AgentHibernationSettings.defaultEnabled,
            idleSeconds: AgentHibernationSettings.defaultIdleSeconds,
            maxLiveTerminals: AgentHibernationSettings.defaultMaxLiveTerminals,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        XCTAssertEqual(notificationCount, 2)
    }

    func testPlannerOnlySelectsIdleUnprotectedExcessLiveAgents() {
        let workspaceId = UUID()
        let now: TimeInterval = 1_000
        let idleOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let idleNew = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let runningOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let needsInputOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let unknownOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let unconfirmedInputOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let visibleOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let settings = AgentHibernationSettings.Values(
            enabled: true,
            idleSeconds: 60,
            maxLiveTerminals: 1,
            confirmationSeconds: 5
        )

        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [
                .init(key: idleOld, hasRestorableAgent: true, isLive: true, isProtected: false, lifecycle: .idle, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
                .init(key: idleNew, hasRestorableAgent: true, isLive: true, isProtected: false, lifecycle: .idle, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 10),
                .init(key: runningOld, hasRestorableAgent: true, isLive: true, isProtected: false, lifecycle: .running, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
                .init(key: needsInputOld, hasRestorableAgent: true, isLive: true, isProtected: false, lifecycle: .needsInput, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
                .init(key: unknownOld, hasRestorableAgent: true, isLive: true, isProtected: false, lifecycle: .unknown, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
                .init(key: unconfirmedInputOld, hasRestorableAgent: true, isLive: true, isProtected: false, lifecycle: .idle, hasUnconfirmedTerminalInput: true, lastActivityAt: now - 300),
                .init(key: visibleOld, hasRestorableAgent: true, isLive: true, isProtected: true, lifecycle: .idle, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
            ],
            settings: settings,
            now: now
        )

        XCTAssertEqual(selected, Set([idleOld]))
    }

    func testPlannerDoesNotSelectWhenUnderLiveLimit() {
        let key = AgentHibernationPanelKey(workspaceId: UUID(), panelId: UUID())
        let settings = AgentHibernationSettings.Values(
            enabled: true,
            idleSeconds: 60,
            maxLiveTerminals: 2,
            confirmationSeconds: 5
        )

        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [
                .init(key: key, hasRestorableAgent: true, isLive: true, isProtected: false, lifecycle: .idle, hasUnconfirmedTerminalInput: false, lastActivityAt: 0),
            ],
            settings: settings,
            now: 1_000
        )

        XCTAssertTrue(selected.isEmpty)
    }

    func testProcessFallbackFingerprintIncludesProcessIDs() {
        let first = AgentHibernationController.processFallbackFingerprint(
            kind: .opencode,
            sessionId: "same-session",
            processIDs: [7, 3]
        )
        let sameIDsDifferentOrder = AgentHibernationController.processFallbackFingerprint(
            kind: .opencode,
            sessionId: "same-session",
            processIDs: [3, 7]
        )
        let restarted = AgentHibernationController.processFallbackFingerprint(
            kind: .opencode,
            sessionId: "same-session",
            processIDs: [8]
        )

        XCTAssertEqual(first, sameIDsDifferentOrder)
        XCTAssertNotEqual(first, restarted)
    }

    func testScrollbackFingerprintIncludesProcessIDs() {
        let first = AgentHibernationController.scrollbackFingerprint(
            tail: "stable tail",
            processIDs: [7, 3]
        )
        let sameIDsDifferentOrder = AgentHibernationController.scrollbackFingerprint(
            tail: "stable tail",
            processIDs: [3, 7]
        )
        let restarted = AgentHibernationController.scrollbackFingerprint(
            tail: "stable tail",
            processIDs: [8]
        )

        XCTAssertEqual(first, sameIDsDifferentOrder)
        XCTAssertNotEqual(first, restarted)
    }

    @MainActor
    func testClearingAgentPIDByPanelClearsLifecycleWithoutOwnedPID() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)
        XCTAssertEqual(workspace.agentHibernationLifecycleState(panelId: panelId, fallback: nil), .idle)

        XCTAssertTrue(workspace.clearAgentPID(key: "codex.missing", panelId: panelId, clearStatus: true))

        XCTAssertEqual(workspace.agentHibernationLifecycleState(panelId: panelId, fallback: nil), .unknown)
    }

    @MainActor
    func testClearingAgentPIDByPanelClearsOnlyThatPanelLifecycleWhenSameStatusKeyRemains() throws {
        let workspace = Workspace()
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        workspace.recordAgentPID(key: "codex.first", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.recordAgentPID(key: "codex.second", pid: 222, panelId: secondPanelId, refreshPorts: false)
        workspace.setAgentLifecycle(key: "codex", panelId: firstPanelId, lifecycle: .idle)
        workspace.setAgentLifecycle(key: "codex", panelId: secondPanelId, lifecycle: .running)

        XCTAssertTrue(workspace.clearAgentPID(key: "codex.first", panelId: firstPanelId, clearStatus: true, refreshPorts: false))

        XCTAssertEqual(workspace.agentHibernationLifecycleState(panelId: firstPanelId, fallback: nil), .unknown)
        XCTAssertEqual(workspace.agentHibernationLifecycleState(panelId: secondPanelId, fallback: nil), .running)
    }

    func testSessionIndexLoadsAgentLifecycleFromHookStore() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-index-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "codex-hibernation-lifecycle"
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "agentLifecycle": "idle",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let index = RestorableAgentSessionIndex.load(homeDirectory: home.path)
        XCTAssertEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        XCTAssertEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId, sessionId)
    }

    func testSessionIndexUsesLiveHookPIDAsProcessID() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-live-hook-pid-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let pid = 12_345
        let sessionId = "codex-live-hook-pid"
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "pid": pid,
                    "agentLifecycle": "idle",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/bin/sleep",
                        "arguments": ["/bin/sleep", "30"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { requestedPID in
                requestedPID == pid
                    ? CmuxTopProcessArguments(
                        arguments: ["/bin/sleep", "30"],
                        environment: [
                            "CMUX_WORKSPACE_ID": workspaceId.uuidString,
                            "CMUX_SURFACE_ID": panelId.uuidString,
                            "CMUX_AGENT_LAUNCH_KIND": RestorableAgentKind.codex.rawValue,
                        ]
                    )
                    : nil
            }
        )

        XCTAssertEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        XCTAssertEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [pid])
        XCTAssertTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
    }

    func testLiveProcessScopeMatchingAcceptsLegacyEnvironmentKeys() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let process = CmuxTopProcessArguments(
            arguments: ["/usr/bin/codex"],
            environment: [
                "CMUX_TAB_ID": workspaceId.uuidString,
                "CMUX_PANEL_ID": panelId.uuidString,
            ]
        )

        XCTAssertTrue(process.matchesCMUXScope(workspaceId: workspaceId, surfaceId: panelId))
        XCTAssertFalse(process.matchesCMUXScope(workspaceId: UUID(), surfaceId: panelId))
        XCTAssertFalse(process.matchesCMUXScope(workspaceId: workspaceId, surfaceId: UUID()))
    }

    func testSessionIndexDoesNotDropHookStoreForUnknownAgentLifecycle() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-index-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "codex-hibernation-future-lifecycle"
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "agentLifecycle": "paused",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let index = RestorableAgentSessionIndex.load(homeDirectory: home.path)
        XCTAssertEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .unknown)
        XCTAssertEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId, sessionId)
    }

    func testProcessDetectedSnapshotPreservesMatchingHookLifecycleWithoutRefreshingActivity() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-detected-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.opencode.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "opencode-detected-lifecycle"
        let hookUpdatedAt: TimeInterval = 123
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "agentLifecycle": "idle",
                    "updatedAt": hookUpdatedAt,
                    "launchCommand": [
                        "launcher": "opencode",
                        "executablePath": "/usr/local/bin/opencode",
                        "arguments": ["/usr/local/bin/opencode"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: sessionId,
            workingDirectory: "/tmp/repo",
            launchCommand: launch(
                "opencode",
                "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode", "--session", sessionId],
                cwd: "/tmp/repo"
            )
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: (snapshot: detectedSnapshot, updatedAt: 999, processIDs: [123, 456])]
        )

        XCTAssertEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        XCTAssertEqual(index.updatedAt(workspaceId: workspaceId, panelId: panelId), hookUpdatedAt)
        XCTAssertEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [123, 456])
        XCTAssertTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
        XCTAssertEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.launchCommand?.executablePath, "/opt/homebrew/bin/opencode")
    }

    func testProcessDetectedSnapshotPreservesMatchingHookLifecycleWhenHookPIDIsStale() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-stale-pid-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.opencode.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "opencode-restored-stale-pid"
        let hookUpdatedAt: TimeInterval = 456
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "pid": 999_999,
                    "agentLifecycle": "idle",
                    "updatedAt": hookUpdatedAt,
                    "launchCommand": [
                        "launcher": "opencode",
                        "executablePath": "/usr/local/bin/opencode",
                        "arguments": ["/usr/local/bin/opencode"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: sessionId,
            workingDirectory: "/tmp/repo",
            launchCommand: launch(
                "opencode",
                "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode", "--session", sessionId],
                cwd: "/tmp/repo"
            )
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: (snapshot: detectedSnapshot, updatedAt: 999, processIDs: [321])]
        )

        XCTAssertEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        XCTAssertEqual(index.updatedAt(workspaceId: workspaceId, panelId: panelId), hookUpdatedAt)
        XCTAssertEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [321])
        XCTAssertEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.launchCommand?.executablePath, "/opt/homebrew/bin/opencode")
    }

    func testProcessDetectedSnapshotPreservesHookLifecycleWhenRestoredPanelIDsChange() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-remapped-panel-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.opencode.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let oldWorkspaceId = UUID()
        let oldPanelId = UUID()
        let currentWorkspaceId = UUID()
        let currentPanelId = UUID()
        let sessionId = "opencode-restored-remapped-panel"
        let hookUpdatedAt: TimeInterval = 789
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": oldWorkspaceId.uuidString,
                    "surfaceId": oldPanelId.uuidString,
                    "cwd": "/tmp/repo",
                    "pid": 999_998,
                    "agentLifecycle": "idle",
                    "updatedAt": hookUpdatedAt,
                    "launchCommand": [
                        "launcher": "opencode",
                        "executablePath": "/usr/local/bin/opencode",
                        "arguments": ["/usr/local/bin/opencode"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: currentWorkspaceId, panelId: currentPanelId)
        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: sessionId,
            workingDirectory: "/tmp/repo",
            launchCommand: launch(
                "opencode",
                "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode", "--session", sessionId],
                cwd: "/tmp/repo"
            )
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: (snapshot: detectedSnapshot, updatedAt: 999, processIDs: [654])]
        )

        XCTAssertNil(index.snapshot(workspaceId: oldWorkspaceId, panelId: oldPanelId))
        XCTAssertEqual(index.lifecycle(workspaceId: currentWorkspaceId, panelId: currentPanelId), .idle)
        XCTAssertEqual(index.updatedAt(workspaceId: currentWorkspaceId, panelId: currentPanelId), hookUpdatedAt)
        XCTAssertEqual(index.processIDs(workspaceId: currentWorkspaceId, panelId: currentPanelId), [654])
    }

    func testProcessDetectedOnlySnapshotDoesNotUseScanTimeAsActivity() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-empty-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-detected-only",
            workingDirectory: "/tmp/repo",
            launchCommand: launch("opencode", "/usr/local/bin/opencode", cwd: "/tmp/repo")
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: (snapshot: detectedSnapshot, updatedAt: 999, processIDs: [789])]
        )

        XCTAssertEqual(index.updatedAt(workspaceId: workspaceId, panelId: panelId), 0)
        XCTAssertNil(index.lifecycle(workspaceId: workspaceId, panelId: panelId))
        XCTAssertEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [789])
        XCTAssertTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
    }

    func testSupportedAgentSnapshotsHaveResumeCommandsForHibernation() {
        let cwd = "/tmp/cmux-agent-hibernation"
        let sessionId = "session-123"
        let launchCommands: [(RestorableAgentKind, AgentLaunchCommandSnapshot)] = [
            (.claude, launch("claude", "/usr/local/bin/claude", cwd: cwd)),
            (.codex, launch("codex", "/usr/local/bin/codex", cwd: cwd)),
            (.opencode, launch("opencode", "/usr/local/bin/opencode", cwd: cwd)),
            (.pi, launch("pi", "/usr/local/bin/pi", cwd: cwd)),
            (.amp, launch("amp", "/usr/local/bin/amp", cwd: cwd)),
            (.cursor, launch("cursor", "/usr/local/bin/cursor-agent", cwd: cwd)),
            (.gemini, launch("gemini", "/usr/local/bin/gemini", cwd: cwd)),
            (.rovodev, launch("rovodev", "/usr/local/bin/acli", arguments: ["/usr/local/bin/acli", "rovodev", "run"], cwd: cwd)),
            (.hermesAgent, launch("hermes-agent", "/usr/local/bin/hermes", cwd: cwd)),
            (.copilot, launch("copilot", "/usr/local/bin/copilot", cwd: cwd)),
            (.codebuddy, launch("codebuddy", "/usr/local/bin/codebuddy", cwd: cwd)),
            (.factory, launch("factory", "/usr/local/bin/droid", cwd: cwd)),
            (.qoder, launch("qoder", "/usr/local/bin/qodercli", cwd: cwd)),
        ]

        for (kind, launchCommand) in launchCommands {
            let snapshot = SessionRestorableAgentSnapshot(
                kind: kind,
                sessionId: sessionId,
                workingDirectory: cwd,
                launchCommand: launchCommand
            )
            XCTAssertNotNil(snapshot.resumeCommand, "\(kind.rawValue) should be resumable before hibernation can use it")
            XCTAssertFalse(snapshot.agentDisplayName.isEmpty)
        }
    }

    func testCustomRegisteredAgentSnapshotCanHibernateWhenResumeCommandExists() {
        let registration = CmuxVaultAgentRegistration(
            id: "local-agent",
            name: "Local Agent",
            detect: CmuxVaultAgentDetectRule(processName: "local-agent"),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: "{{executable}} resume {{sessionId}}",
            cwd: .preserve
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("local-agent"),
            sessionId: "custom-session",
            workingDirectory: "/tmp/custom-agent",
            launchCommand: launch("local-agent", "/usr/local/bin/local-agent", cwd: "/tmp/custom-agent"),
            registration: registration
        )

        XCTAssertEqual(snapshot.agentDisplayName, "Local Agent")
        XCTAssertEqual(snapshot.resumeCommand, "cd '/tmp/custom-agent' && '/usr/local/bin/local-agent' 'resume' 'custom-session'")
    }

    @MainActor
    func testFocusingHibernatedTerminalAutomaticallyPreparesResume() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-auto-resume-on-visit",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isAgentHibernated)

        workspace.focusPanel(panelId)

        XCTAssertFalse(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    func testVisibleHibernatedTerminalAutomaticallyPreparesResumeWithoutFocus() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-visible-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isAgentHibernated)

        XCTAssertTrue(workspace.resumeVisibleAgentHibernationPanels(panelIds: [panelId]))

        XCTAssertFalse(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    func testDirectFocusOnHibernatedTerminalPreparesResumeWithoutHiddenFocus() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-direct-focus-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isAgentHibernated)

        panel.focus()

        XCTAssertFalse(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    func testExplicitInputToHibernatedTerminalQueuesAndPreparesResume() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-explicit-input-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .manualResumeAvailable)

        let result = panel.sendInputResult("pwd\r")

        XCTAssertEqual(result, .queued)
        XCTAssertFalse(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    func testExplicitNamedKeyToHibernatedTerminalQueuesAndPreparesResume() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-explicit-key-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .manualResumeAvailable)

        let result = panel.sendNamedKeyResult("enter")

        XCTAssertEqual(result, .queued)
        XCTAssertFalse(panel.isAgentHibernated)
        XCTAssertEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    private func launch(
        _ launcher: String,
        _ executablePath: String,
        arguments: [String] = [],
        cwd: String
    ) -> AgentLaunchCommandSnapshot {
        AgentLaunchCommandSnapshot(
            launcher: launcher,
            executablePath: executablePath,
            arguments: arguments.isEmpty ? [executablePath] : arguments,
            workingDirectory: cwd,
            environment: nil,
            capturedAt: nil,
            source: nil
        )
    }
}
