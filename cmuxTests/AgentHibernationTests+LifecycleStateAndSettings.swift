import Foundation
import XCTest
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Lifecycle state parsing, socket status keys, settings
extension AgentHibernationTests {
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

    func testSocketLifecycleRejectsUnsupportedStatusKey() {
        let response = TerminalController.shared.handleSocketLine("set_agent_lifecycle fake-agent idle")

        XCTAssertTrue(response.contains("Unsupported agent lifecycle key"))
    }

    @MainActor
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

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.panelDirectories[panelId] = root.path

        let response = TerminalController.shared.handleSocketLine(
            "set_agent_lifecycle local-agent idle --tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"
        )
        XCTAssertEqual(response, "OK")
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertEqual(workspace.agentLifecycleStatesByPanelId[panelId]?["local-agent"], .idle)
    }

    func testSettingsDefaultToOptInAndNotifyOnChanges() throws {
        let suiteName = "cmux-agent-hibernation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AgentHibernationSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(AgentHibernationSettings.idleSeconds(defaults: defaults), 5)
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

}
