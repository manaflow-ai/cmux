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
