import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Surface resume binding snapshot and fingerprint
extension SessionPersistenceTests {
    @MainActor
    func testSnapshotPrefersFreshProcessDetectedSurfaceResumeBinding() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(
            workspace.setSurfaceResumeBinding(
                SurfaceResumeBindingSnapshot(
                    name: "tmux",
                    kind: "tmux",
                    command: "tmux attach -t stale",
                    cwd: "/tmp/old",
                    checkpointId: "stale",
                    source: "process-detected",
                    updatedAt: 10
                ),
                panelId: panelId
            )
        )

        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId): SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t fresh",
                cwd: "/tmp/new",
                checkpointId: "fresh",
                source: "process-detected",
                updatedAt: 20
            ),
        ])
        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.checkpointId, "fresh")
        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.command, "tmux attach -t fresh")
        XCTAssertEqual(
            workspace.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding?.checkpointId,
            "fresh"
        )
    }

    @MainActor
    func testSnapshotUsesProcessDetectedSurfaceResumeBindingAfterWorkspaceMove() throws {
        let originalWorkspaceId = UUID()
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: originalWorkspaceId, panelId: panelId): SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t moved",
                cwd: "/tmp/moved",
                checkpointId: "moved",
                source: "process-detected",
                updatedAt: 20
            ),
        ])
        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.checkpointId, "moved")
        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.command, "tmux attach -t moved")
        XCTAssertEqual(
            workspace.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding?.checkpointId,
            "moved"
        )
    }

    @MainActor
    func testSnapshotKeepsExplicitSurfaceResumeBindingOverDetectedBinding() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(
            workspace.setSurfaceResumeBinding(
                SurfaceResumeBindingSnapshot(
                    name: "Codex",
                    kind: "codex",
                    command: "codex resume explicit",
                    cwd: "/tmp/explicit",
                    checkpointId: "explicit",
                    source: "cli",
                    updatedAt: 10
                ),
                panelId: panelId
            )
        )

        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId): SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t detected",
                cwd: "/tmp/detected",
                checkpointId: "detected",
                source: "process-detected",
                updatedAt: 20
            ),
        ])
        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.checkpointId, "explicit")
        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.command, "codex resume explicit")
    }

    @MainActor
    func testSnapshotPrefersProcessDetectedTmuxOverAgentHookBinding() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(
            workspace.setSurfaceResumeBinding(
                SurfaceResumeBindingSnapshot(
                    name: "Codex",
                    kind: "codex",
                    command: "codex resume session",
                    cwd: "/tmp/agent",
                    checkpointId: "session",
                    source: "agent-hook",
                    updatedAt: 10
                ),
                panelId: panelId
            )
        )

        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId): SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t detected",
                cwd: "/tmp/detected",
                checkpointId: "detected",
                source: "process-detected",
                autoResume: true,
                updatedAt: 20
            ),
        ])
        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.checkpointId, "detected")
        XCTAssertEqual(snapshot.panels.first?.terminal?.resumeBinding?.command, "tmux attach -t detected")
        XCTAssertEqual(
            workspace.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding?.checkpointId,
            "detected"
        )
    }

    @MainActor
    func testAutosaveFingerprintIgnoresSurfaceResumeBindingUpdatedAt() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let key = SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let firstIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t work",
                cwd: "/tmp/project",
                checkpointId: "work",
                source: "process-detected",
                updatedAt: 10
            ),
        ])
        let secondIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t work",
                cwd: "/tmp/project",
                checkpointId: "work",
                source: "process-detected",
                updatedAt: 20
            ),
        ])

        XCTAssertEqual(
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: firstIndex),
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: secondIndex)
        )
    }

    @MainActor
    func testAutosaveFingerprintIncludesManualSurfaceResumeBindingUpdatedAt() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let key = SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let firstIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "custom",
                kind: "custom",
                command: "echo one",
                cwd: "/tmp/project",
                checkpointId: "custom",
                source: "cli",
                updatedAt: 10
            ),
        ])
        let secondIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "custom",
                kind: "custom",
                command: "echo one",
                cwd: "/tmp/project",
                checkpointId: "custom",
                source: "cli",
                updatedAt: 20
            ),
        ])

        XCTAssertNotEqual(
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: firstIndex),
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: secondIndex)
        )
    }

    @MainActor
    func testAutosaveFingerprintUsesEffectiveSurfaceResumeBinding() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(
            workspace.setSurfaceResumeBinding(
                SurfaceResumeBindingSnapshot(
                    name: "tmux",
                    kind: "tmux",
                    command: "tmux attach -t stale",
                    cwd: "/tmp/stale",
                    checkpointId: "stale",
                    source: "process-detected",
                    updatedAt: 10
                ),
                panelId: panelId
            )
        )

        let key = SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let firstIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t first",
                cwd: "/tmp/first",
                checkpointId: "first",
                source: "process-detected",
                updatedAt: 20
            ),
        ])
        let secondIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t second",
                cwd: "/tmp/second",
                checkpointId: "second",
                source: "process-detected",
                updatedAt: 30
            ),
        ])

        XCTAssertNotEqual(
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: firstIndex),
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: secondIndex)
        )
    }

    @MainActor
    func testAutosaveFingerprintIncludesSurfaceResumeBindingEnvironment() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let key = SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let firstIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume session",
                cwd: "/tmp/project",
                checkpointId: "session",
                source: "agent-hook",
                environment: ["CODEX_HOME": "/tmp/codex-a"],
                updatedAt: 10
            ),
        ])
        let secondIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume session",
                cwd: "/tmp/project",
                checkpointId: "session",
                source: "agent-hook",
                environment: ["CODEX_HOME": "/tmp/codex-b"],
                updatedAt: 10
            ),
        ])

        XCTAssertNotEqual(
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: firstIndex),
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: secondIndex)
        )
    }

    @MainActor
    func testAutosaveFingerprintIncludesSurfaceResumeBindingAutoResumeTrust() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let key = SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let untrustedIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t work",
                cwd: "/tmp/project",
                checkpointId: "work",
                source: "process-detected",
                updatedAt: 10
            ),
        ])
        let trustedIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            key: SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t work",
                cwd: "/tmp/project",
                checkpointId: "work",
                source: "process-detected",
                autoResume: true,
                updatedAt: 10
            ),
        ])

        XCTAssertNotEqual(
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: untrustedIndex),
            manager.sessionAutosaveFingerprint(surfaceResumeBindingIndex: trustedIndex)
        )
    }

    @MainActor
    func testAutosaveFingerprintIncludesTextBoxDraftContent() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let terminalPanel = try XCTUnwrap(workspace.terminalPanel(for: panelId))

        let baselineFingerprint = manager.sessionAutosaveFingerprint()
        terminalPanel.restoreSessionTextBoxDraft(SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: [.text("draft one")]
        ))
        let firstTextFingerprint = manager.sessionAutosaveFingerprint()
        XCTAssertNotEqual(baselineFingerprint, firstTextFingerprint)

        terminalPanel.restoreSessionTextBoxDraft(SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: [.text("draft two")]
        ))
        let secondTextFingerprint = manager.sessionAutosaveFingerprint()
        XCTAssertNotEqual(firstTextFingerprint, secondTextFingerprint)

        let attachment = SessionTextBoxInputAttachmentSnapshot(
            displayName: "moon.png",
            submissionText: "/tmp/moon.png",
            submissionPath: "/tmp/moon.png",
            localPath: "/tmp/moon.png",
            cleanupLocalPathWhenDisposed: false
        )
        terminalPanel.restoreSessionTextBoxDraft(SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: [.text("look "), .attachment(attachment)]
        ))
        let imageDraftFingerprint = manager.sessionAutosaveFingerprint()
        XCTAssertNotEqual(secondTextFingerprint, imageDraftFingerprint)

        terminalPanel.restoreSessionTextBoxDraft(SessionTextBoxInputDraftSnapshot(
            isActive: false,
            parts: [.text("look "), .attachment(attachment)]
        ))
        XCTAssertNotEqual(imageDraftFingerprint, manager.sessionAutosaveFingerprint())
    }

    func testSurfaceResumeBindingPreservesExactNonSensitiveEnvironmentValues() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "codex resume session",
            environment: [
                " EMPTY ": "",
                "SPACED": "  keep exact  ",
                "PLAIN": "value",
                "MULTILINE": "line\nbreak",
                "NULL_BYTE": "bad\u{0}value",
                "ANTHROPIC_API_KEY": "should-not-persist",
                "SERVICE_TOKEN": "should-not-persist",
            ]
        )

        XCTAssertEqual(binding.environment?["EMPTY"], "")
        XCTAssertEqual(binding.environment?["SPACED"], "  keep exact  ")
        XCTAssertEqual(binding.environment?["PLAIN"], "value")
        XCTAssertNil(binding.environment?["MULTILINE"])
        XCTAssertNil(binding.environment?["NULL_BYTE"])
        XCTAssertNil(binding.environment?["ANTHROPIC_API_KEY"])
        XCTAssertNil(binding.environment?["SERVICE_TOKEN"])
    }

}
