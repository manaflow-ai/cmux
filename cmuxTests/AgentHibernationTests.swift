import Foundation
import Testing
import Bonsplit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentHibernationTests {
    @Test
    func testLifecycleStateParsingAcceptsShellFriendlyAliases() throws {
        expectEqual(AgentHibernationLifecycleState.parseCLIValue("IDLE"), .idle)
        expectEqual(AgentHibernationLifecycleState.parseCLIValue("needsInput"), .needsInput)
        expectEqual(AgentHibernationLifecycleState.parseCLIValue("needs-input"), .needsInput)
        expectEqual(AgentHibernationLifecycleState.parseCLIValue("needs_input"), .needsInput)
        expectNil(AgentHibernationLifecycleState.parseCLIValue("paused"))

        let decoded = try JSONDecoder().decode(
            AgentHibernationLifecycleState.self,
            from: Data(#""paused""#.utf8)
        )
        expectEqual(decoded, .unknown)
    }

    @MainActor
    @Test
    func testSocketLifecycleRejectsUnsupportedStatusKey() {
        let response = TerminalController.shared.handleSocketLine("set_agent_lifecycle fake-agent idle")

        expectTrue(response.contains("Unsupported agent lifecycle key"))
    }

    @MainActor
    @Test
    func testSocketLifecycleAcceptsRegisteredCustomAgentKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-custom-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try """
        {
          "vault": {
            "agents": [
              {
                "id": "local-agent",
                "name": "Local Agent",
                "detect": { "processName": "local-agent" },
                "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
                "resumeCommand": "local-agent --session {{sessionId}}",
                "cwd": "preserve"
              }
            ]
          }
        }
        """.write(to: configDirectory.appendingPathComponent("cmux.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            TerminalMutationBus.shared.drainForTesting()
        }

        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.panelDirectories[panelId] = root.path

        let response = TerminalController.shared.handleSocketLine(
            "set_agent_lifecycle local-agent idle --tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"
        )
        expectEqual(response, "OK")
        TerminalMutationBus.shared.drainForTesting()

        expectEqual(workspace.agentLifecycleStatesByPanelId[panelId]?["local-agent"], .idle)
    }

    @Test
    func testSettingsDefaultToOptInAndNotifyOnChanges() throws {
        let suiteName = "cmux-agent-hibernation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        expectFalse(AgentHibernationSettings.isEnabled(defaults: defaults))
        expectEqual(AgentHibernationSettings.idleSeconds(defaults: defaults), 5)
        expectEqual(AgentHibernationSettings.maxLiveTerminals(defaults: defaults), 12)

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
        expectTrue(values.enabled)
        expectEqual(values.idleSeconds, 10)
        expectEqual(values.maxLiveTerminals, 4)
        expectEqual(notificationCount, 1)

        defaults.set(42, forKey: AgentHibernationSettings.confirmationSecondsKey)
        expectEqual(AgentHibernationSettings.confirmationSeconds(defaults: defaults), 42)
        AgentHibernationSettings.reset(defaults: defaults, notificationCenter: notificationCenter)
        expectEqual(AgentHibernationSettings.confirmationSeconds(defaults: defaults), AgentHibernationSettings.defaultConfirmationSeconds)
        expectNil(defaults.object(forKey: AgentHibernationSettings.confirmationSecondsKey))
        expectEqual(notificationCount, 2)

        AgentHibernationSettings.setValues(
            enabled: AgentHibernationSettings.defaultEnabled,
            idleSeconds: AgentHibernationSettings.defaultIdleSeconds,
            maxLiveTerminals: AgentHibernationSettings.defaultMaxLiveTerminals,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        expectEqual(notificationCount, 2)
    }

    @Test
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

        expectEqual(selected, Set([idleOld]))
    }

    @Test
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

        expectTrue(selected.isEmpty)
    }

    @Test
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

        expectEqual(first, sameIDsDifferentOrder)
        expectNotEqual(first, restarted)
    }

    @Test
    func testFirstTailSampleStartsObservedStabilityWindow() {
        expectEqual(
            AgentHibernationController.tailFingerprintStableSince(
                previousFingerprint: nil,
                previousStableSince: nil,
                currentFingerprint: "tail-a",
                lastActivityAt: 100,
                now: 500
            ),
            500
        )
        expectEqual(
            AgentHibernationController.tailFingerprintStableSince(
                previousFingerprint: "tail-a",
                previousStableSince: 100,
                currentFingerprint: "tail-a",
                lastActivityAt: 120,
                now: 500
            ),
            100
        )
        expectEqual(
            AgentHibernationController.tailFingerprintStableSince(
                previousFingerprint: "tail-a",
                previousStableSince: 100,
                currentFingerprint: "tail-b",
                lastActivityAt: 120,
                now: 500
            ),
            500
        )
    }

    @MainActor
    @Test
    func testClearingAgentPIDByPanelClearsLifecycleWithoutOwnedPID() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)
        expectEqual(workspace.agentHibernationLifecycleState(panelId: panelId, fallback: nil), .idle)

        expectTrue(workspace.clearAgentPID(key: "codex.missing", panelId: panelId, clearStatus: true))

        expectEqual(workspace.agentHibernationLifecycleState(panelId: panelId, fallback: nil), .unknown)
    }

    @MainActor
    @Test
    func testClearingAgentPIDByPanelClearsOnlyThatPanelLifecycleWhenSameStatusKeyRemains() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        workspace.recordAgentPID(key: "codex.first", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.recordAgentPID(key: "codex.second", pid: 222, panelId: secondPanelId, refreshPorts: false)
        workspace.setAgentLifecycle(key: "codex", panelId: firstPanelId, lifecycle: .idle)
        workspace.setAgentLifecycle(key: "codex", panelId: secondPanelId, lifecycle: .running)

        expectTrue(workspace.clearAgentPID(key: "codex.first", panelId: firstPanelId, clearStatus: true, refreshPorts: false))

        expectEqual(workspace.agentHibernationLifecycleState(panelId: firstPanelId, fallback: nil), .unknown)
        expectEqual(workspace.agentHibernationLifecycleState(panelId: secondPanelId, fallback: nil), .running)
    }

    @Test
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
        expectEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        expectEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId, sessionId)
    }

    @Test
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

        expectEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        expectEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [pid])
        expectTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
    }

    @Test
    func testSessionIndexAcceptsNodeBackedClaudeProcessAsLiveHookPID() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-claude-node-pid-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.claude.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let pid = 23_456
        let sessionId = "claude-node-live-hook-pid"
        let transcriptURL = home
            .appendingPathComponent(".claude/projects/-tmp-repo", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"type":"summary","summary":"Claude session"}"#.write(
            to: transcriptURL,
            atomically: true,
            encoding: .utf8
        )

        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "transcriptPath": transcriptURL.path,
                    "pid": pid,
                    "agentLifecycle": "idle",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "claude",
                        "executablePath": "/opt/homebrew/bin/claude",
                        "arguments": ["/opt/homebrew/bin/claude"],
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
                        arguments: [
                            "/opt/homebrew/Cellar/node/24.0.0/bin/node",
                            "/Users/example/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js",
                        ],
                        environment: [
                            "CMUX_WORKSPACE_ID": workspaceId.uuidString,
                            "CMUX_SURFACE_ID": panelId.uuidString,
                            "CMUX_AGENT_LAUNCH_KIND": RestorableAgentKind.claude.rawValue,
                        ]
                    )
                    : nil
            }
        )

        expectEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        expectEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [pid])
        expectTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
    }

    @Test
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

        expectTrue(process.matchesCMUXScope(workspaceId: workspaceId, surfaceId: panelId))
        expectFalse(process.matchesCMUXScope(workspaceId: UUID(), surfaceId: panelId))
        expectFalse(process.matchesCMUXScope(workspaceId: workspaceId, surfaceId: UUID()))
    }

    @Test
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
        expectEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .unknown)
        expectEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId, sessionId)
    }

    @Test
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
            detectedSnapshots: [
                key: (
                    snapshot: detectedSnapshot,
                    updatedAt: 999,
                    processIDs: Set([123, 456]), agentProcessIDs: Set([123]),
                    sessionIDSource: .explicit
                ),
            ]
        )

        expectEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        expectEqual(index.updatedAt(workspaceId: workspaceId, panelId: panelId), hookUpdatedAt)
        expectEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [123, 456])
        expectTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
        expectEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.launchCommand?.executablePath, "/opt/homebrew/bin/opencode")
    }

    @Test
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
            detectedSnapshots: [
                key: (
                    snapshot: detectedSnapshot,
                    updatedAt: 999,
                    processIDs: Set([321]), agentProcessIDs: Set([321]),
                    sessionIDSource: .explicit
                ),
            ]
        )

        expectEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        expectEqual(index.updatedAt(workspaceId: workspaceId, panelId: panelId), hookUpdatedAt)
        expectEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [321])
        expectEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.launchCommand?.executablePath, "/opt/homebrew/bin/opencode")
    }

    @Test
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
            detectedSnapshots: [
                key: (
                    snapshot: detectedSnapshot,
                    updatedAt: 999,
                    processIDs: Set([654]), agentProcessIDs: Set([654]),
                    sessionIDSource: .explicit
                ),
            ]
        )

        expectNil(index.snapshot(workspaceId: oldWorkspaceId, panelId: oldPanelId))
        expectEqual(index.lifecycle(workspaceId: currentWorkspaceId, panelId: currentPanelId), .idle)
        expectEqual(index.updatedAt(workspaceId: currentWorkspaceId, panelId: currentPanelId), hookUpdatedAt)
        expectEqual(index.processIDs(workspaceId: currentWorkspaceId, panelId: currentPanelId), [654])
    }

    @Test
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
            detectedSnapshots: [
                key: (
                    snapshot: detectedSnapshot,
                    updatedAt: 999,
                    processIDs: Set([789]), agentProcessIDs: Set([789]),
                    sessionIDSource: .explicit
                ),
            ]
        )

        expectEqual(index.updatedAt(workspaceId: workspaceId, panelId: panelId), 0)
        expectNil(index.lifecycle(workspaceId: workspaceId, panelId: panelId))
        expectEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [789])
        expectTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
    }

    @Test
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
            expectNotNil(snapshot.resumeCommand, "\(kind.rawValue) should be resumable before hibernation can use it")
            expectFalse(snapshot.agentDisplayName.isEmpty)
        }
    }

    @Test
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

        expectEqual(snapshot.agentDisplayName, "Local Agent")
        expectEqual(snapshot.resumeCommand, "cd -- '/tmp/custom-agent' 2>/dev/null || [ ! -d '/tmp/custom-agent' ] && '/usr/local/bin/local-agent' 'resume' 'custom-session'")
    }

    @MainActor
    @Test
    func testInvalidatedIndexedAgentSnapshotIsNotEligibleForHibernation() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-invalidated-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-invalidated-index",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                key: (
                    snapshot: snapshot,
                    updatedAt: 100,
                    processIDs: Set([42]), agentProcessIDs: Set([42]),
                    sessionIDSource: .explicit
                ),
            ]
        )

        workspace.invalidatedRestoredAgentFingerprintsByPanelId[panelId] =
            TabManager.restorableAgentSnapshotFingerprint(snapshot)

        expectNil(workspace.restorableAgentForHibernation(panelId: panelId, index: index))
    }

    @MainActor
    @Test
    func testFocusingHibernatedTerminalAutomaticallyPreparesResume() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
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
        expectTrue(panel.isAgentHibernated)

        workspace.focusPanel(panelId)

        expectFalse(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    @Test
    func testVisibleHibernatedTerminalAutomaticallyPreparesResumeWithoutFocus() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
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
        expectTrue(panel.isAgentHibernated)

        expectTrue(workspace.resumeVisibleAgentHibernationPanels(panelIds: [panelId]))

        expectFalse(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    @Test
    func testHiddenMountedWorkspaceDoesNotAutoResumeHibernatedTerminal() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-hidden-mounted-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        expectTrue(panel.isAgentHibernated)

        workspace.setAgentHibernationAutoResumePresentationVisible(false)
        expectEqual(workspace.agentHibernationVisiblePanelIdsForCurrentLayout(), [])

        _ = workspace.debugReconcileTerminalPortalVisibilityForTesting()
        expectTrue(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .manualResumeAvailable)

        workspace.setAgentHibernationAutoResumePresentationVisible(true)

        expectFalse(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    @Test
    func testAutosaveFingerprintTracksHibernationTransitions() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-autosave-hibernation",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        let liveFingerprint = manager.sessionAutosaveFingerprint()
        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
        let hibernatedFingerprint = manager.sessionAutosaveFingerprint()

        expectNotEqual(liveFingerprint, hibernatedFingerprint)
        expectTrue(workspace.resumeAgentHibernation(panelId: panelId, focus: false))
        expectNotEqual(hibernatedFingerprint, manager.sessionAutosaveFingerprint())
    }

    @MainActor
    @Test
    func testResumeClearsStaleLifecycleState() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-clear-lifecycle-on-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)
        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )

        expectTrue(workspace.resumeAgentHibernation(panelId: panelId, focus: false))
        expectEqual(workspace.agentHibernationLifecycleState(panelId: panelId, fallback: nil), .unknown)
    }

    @MainActor
    @Test
    func testDirectFocusOnHibernatedTerminalPreparesResumeWithoutHiddenFocus() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
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
        expectTrue(panel.isAgentHibernated)

        panel.focus()

        expectFalse(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    @Test
    func testExplicitInputToHibernatedTerminalQueuesAndPreparesResume() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
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
        expectTrue(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .manualResumeAvailable)

        let result = panel.sendInputResult("pwd\r")

        expectEqual(result, .queued)
        expectFalse(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    @Test
    func testMovedHibernatedTerminalResumesThroughDestinationWorkspace() throws {
        let source = Workspace()
        let panelId = try #require(source.focusedPanelId)
        let panel = try #require(source.panels[panelId] as? TerminalPanel)
        let detached = try #require(source.detachSurface(panelId: panelId))

        let destination = Workspace()
        let destinationPaneId = try #require(destination.bonsplitController.focusedPaneId)
        expectEqual(
            destination.attachDetachedSurface(detached, inPane: destinationPaneId, focus: false),
            panelId
        )

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-moved-explicit-input-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )
        destination.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        expectTrue(panel.isAgentHibernated)

        let result = panel.sendInputResult("pwd\r")

        expectEqual(result, .queued)
        expectFalse(panel.isAgentHibernated)
        expectNil(source.restoredAgentResumeStatesByPanelId[panelId])
        expectEqual(destination.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    @Test
    func testExplicitNamedKeyToHibernatedTerminalQueuesAndPreparesResume() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
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
        expectTrue(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .manualResumeAvailable)

        let result = panel.sendNamedKeyResult("enter")

        expectEqual(result, .queued)
        expectFalse(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    @Test
    func testResumePreparationWithoutStartupInputStillLeavesHibernation() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("manual-agent"),
            sessionId: "manual-agent-session",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: nil
        )

        panel.enterAgentHibernation(
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        expectTrue(panel.isAgentHibernated)

        let preparation = panel.prepareAgentHibernationResume()

        expectEqual(preparation, .resumed(queuedStartupInput: false))
        expectFalse(panel.isAgentHibernated)
        expectFalse(panel.surface.debugInitialInputMetadata().hasInitialInput)
    }

}
