import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentSessionAutoResumeSettingsTests: XCTestCase {
    func testDefaultsKeyAndNotificationOnFlip() throws {
        let suiteName = "cmux-agent-session-auto-resume-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey,
            "terminal.autoResumeAgentSessions"
        )
        XCTAssertTrue(AgentSessionAutoResumeSettings.isEnabled(defaults: defaults))

        let notificationCenter = NotificationCenter()
        var notificationCount = 0
        let observer = notificationCenter.addObserver(
            forName: AgentSessionAutoResumeSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { notificationCenter.removeObserver(observer) }

        AgentSessionAutoResumeSettings.setEnabled(
            false,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        XCTAssertFalse(AgentSessionAutoResumeSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(notificationCount, 1)

        AgentSessionAutoResumeSettings.setEnabled(
            false,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        XCTAssertEqual(notificationCount, 1)

        AgentSessionAutoResumeSettings.reset(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        XCTAssertTrue(AgentSessionAutoResumeSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(notificationCount, 2)
    }

    @MainActor
    func testDisabledAutoResumeDoesNotInjectStartupInputOnRestore() throws {
        let defaults = UserDefaults.standard
        let key = AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let sourceIndex = try makeRestorableAgentIndex(
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: "codex-auto-resume-disabled-session"
        )
        let snapshot = source.sessionSnapshot(includeScrollback: false, restorableAgentIndex: sourceIndex)

        defaults.removeObject(forKey: key)
        let restoredWithAutoResume = Workspace()
        restoredWithAutoResume.restoreSessionSnapshot(snapshot)
        let autoResumePanelId = try XCTUnwrap(restoredWithAutoResume.focusedPanelId)
        let autoResumePanel = try XCTUnwrap(restoredWithAutoResume.terminalPanel(for: autoResumePanelId))
        let autoResumeInput = autoResumePanel.surface.debugInitialInputMetadata()
        XCTAssertTrue(autoResumeInput.hasInitialInput)
        XCTAssertGreaterThan(autoResumeInput.byteCount, 0)

        defaults.set(false, forKey: key)
        let restoredWithoutAutoResume = Workspace()
        restoredWithoutAutoResume.restoreSessionSnapshot(snapshot)
        let disabledPanelId = try XCTUnwrap(restoredWithoutAutoResume.focusedPanelId)
        let disabledPanel = try XCTUnwrap(restoredWithoutAutoResume.terminalPanel(for: disabledPanelId))
        let disabledInput = disabledPanel.surface.debugInitialInputMetadata()
        XCTAssertFalse(disabledInput.hasInitialInput)
        XCTAssertEqual(disabledInput.byteCount, 0)
        XCTAssertEqual(
            restoredWithoutAutoResume.sessionSnapshot(includeScrollback: false)
                .panels.first?.terminal?.agent?.sessionId,
            "codex-auto-resume-disabled-session"
        )

        restoredWithoutAutoResume.updatePanelShellActivityState(panelId: disabledPanelId, state: .commandRunning)
        XCTAssertNil(restoredWithoutAutoResume.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent)
    }

    private func makeRestorableAgentIndex(
        workspaceId: UUID,
        panelId: UUID,
        sessionId: String
    ) throws -> RestorableAgentSessionIndex {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-auto-resume-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex", "--model", "gpt-5.4"],
                        "workingDirectory": "/tmp/repo",
                        "environment": ["CODEX_HOME": "/tmp/codex"],
                        "capturedAt": Date().timeIntervalSince1970,
                        "source": "process",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)
        return RestorableAgentSessionIndex.load(homeDirectory: home.path)
    }
}
