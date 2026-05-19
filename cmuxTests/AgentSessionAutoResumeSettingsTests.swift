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

        restoredWithoutAutoResume.updatePanelShellActivityState(panelId: disabledPanelId, state: .promptIdle)
        XCTAssertEqual(
            restoredWithoutAutoResume.sessionSnapshot(includeScrollback: false)
                .panels.first?.terminal?.agent?.sessionId,
            "codex-auto-resume-disabled-session"
        )

        restoredWithoutAutoResume.updatePanelShellActivityState(panelId: disabledPanelId, state: .commandRunning)
        XCTAssertNil(restoredWithoutAutoResume.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent)
    }

    @MainActor
    func testDisabledAutoResumeDoesNotRunAgentHookResumeBinding() throws {
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
            sessionId: "codex-binding-auto-resume-disabled-session"
        )
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume codex-binding-auto-resume-disabled-session",
                cwd: "/tmp/repo",
                checkpointId: "codex-binding-auto-resume-disabled-session",
                source: "agent-hook",
                updatedAt: 1_777_777_777
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: sourceIndex,
            surfaceResumeBindingIndex: bindingIndex
        )

        defaults.set(false, forKey: key)
        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
        let input = restoredPanel.surface.debugInitialInputMetadata()

        XCTAssertFalse(input.hasInitialInput)
        XCTAssertEqual(input.byteCount, 0)
        XCTAssertEqual(
            restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding?.source,
            "agent-hook"
        )
        XCTAssertEqual(
            restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent?.sessionId,
            "codex-binding-auto-resume-disabled-session"
        )

        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        let userCommandSnapshot = restored.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(userCommandSnapshot.panels.first?.terminal?.agent)
        XCTAssertNil(userCommandSnapshot.panels.first?.terminal?.resumeBinding)
    }

    @MainActor
    func testDisabledAutoResumeKeepsScrollbackForSuppressedAgentHookBinding() throws {
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
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "OpenCode",
                kind: "opencode",
                command: "opencode --session suppressed-binding-session",
                cwd: "/tmp/repo",
                checkpointId: "suppressed-binding-session",
                source: "agent-hook",
                updatedAt: 1_777_777_777
            ),
        ])
        var snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )
        let panelIndex = try XCTUnwrap(snapshot.panels.indices.first)
        let savedScrollback = "previous output\n"
        snapshot.panels[panelIndex].terminal?.scrollback = savedScrollback

        defaults.set(false, forKey: key)
        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
        let input = restoredPanel.surface.debugInitialInputMetadata()

        XCTAssertFalse(input.hasInitialInput)
        XCTAssertEqual(input.byteCount, 0)
        XCTAssertEqual(
            restored.sessionSnapshot(includeScrollback: true).panels.first?.terminal?.scrollback,
            savedScrollback
        )
    }

    @MainActor
    func testAgentHookResumeBindingKeepsRestoredAgentPendingDuringStartupCommand() throws {
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
        defaults.set(true, forKey: key)

        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let sourceIndex = try makeRestorableAgentIndex(
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: "codex-binding-auto-resume-session"
        )
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume codex-binding-auto-resume-session",
                cwd: "/tmp/repo",
                checkpointId: "codex-binding-auto-resume-session",
                source: "agent-hook",
                autoResume: true,
                updatedAt: 1_777_777_777
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: sourceIndex,
            surfaceResumeBindingIndex: bindingIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
        XCTAssertTrue(restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)

        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        XCTAssertEqual(
            restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent?.sessionId,
            "codex-binding-auto-resume-session"
        )

        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .promptIdle)
        let completedSnapshot = restored.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(completedSnapshot.panels.first?.terminal?.agent)
        XCTAssertNil(completedSnapshot.panels.first?.terminal?.resumeBinding)
    }

    @MainActor
    func testNonAgentResumeBindingDoesNotMarkRestoredAgentAwaitingAutoResume() throws {
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
        defaults.set(true, forKey: key)

        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let sourceIndex = try makeRestorableAgentIndex(
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: "codex-agent-inside-tmux-session"
        )
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "tmux work",
                kind: "tmux",
                command: "tmux attach -t work",
                cwd: "/tmp/repo",
                checkpointId: "work",
                source: "process-detected",
                autoResume: true,
                updatedAt: 1_777_777_777
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: sourceIndex,
            surfaceResumeBindingIndex: bindingIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
        XCTAssertTrue(restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)

        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        let runningSnapshot = restored.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(runningSnapshot.panels.first?.terminal?.agent)
        XCTAssertEqual(runningSnapshot.panels.first?.terminal?.resumeBinding?.kind, "tmux")
    }

    private func makeRestorableAgentIndex(
        workspaceId: UUID,
        panelId: UUID,
        sessionId: String
    ) throws -> RestorableAgentSessionIndex {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-auto-resume-\(UUID().uuidString)", isDirectory: true)
        let previousHookStateDir = getenv("CMUX_AGENT_HOOK_STATE_DIR").map { String(cString: $0) }
        setenv("CMUX_AGENT_HOOK_STATE_DIR", home.appendingPathComponent("hook-state", isDirectory: true).path, 1)
        defer {
            if let previousHookStateDir {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDir, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
        }
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
