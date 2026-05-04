import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RestorableCodexTitleTests: XCTestCase {
    @MainActor
    func testCodexTitleSlugPersistsRestorableAgentWhenHookStoreMissing() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        workspace.updatePanelDirectory(panelId: panelId, directory: "/tmp/repo")
        XCTAssertTrue(workspace.updatePanelTitle(panelId: panelId, title: "codex-019df0a1-6"))

        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty
        )
        let agent = try XCTUnwrap(snapshot.panels.first?.terminal?.agent)

        XCTAssertEqual(agent.kind, .codex)
        XCTAssertEqual(agent.sessionId, "codex-019df0a1-6")
        XCTAssertEqual(agent.launchCommand?.source, "surface-title")
        XCTAssertEqual(
            agent.resumeCommand,
            "cd '/tmp/repo' && 'codex' 'resume' '--dangerously-bypass-approvals-and-sandbox' 'codex-019df0a1-6'"
        )
    }

    @MainActor
    func testCodexTitleSlugStopsPersistingAfterPromptReturns() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        XCTAssertTrue(workspace.updatePanelTitle(panelId: panelId, title: "codex-019df0a1-6"))

        XCTAssertEqual(
            workspace.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent?.sessionId,
            "codex-019df0a1-6"
        )

        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        XCTAssertNil(workspace.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent)
    }

    @MainActor
    func testRestoredCodexTitleResumeClearsAfterPromptReturns() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        XCTAssertTrue(source.updatePanelTitle(panelId: sourcePanelId, title: "codex-019df0a1-6"))
        let snapshot = source.sessionSnapshot(includeScrollback: false, restorableAgentIndex: .empty)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        XCTAssertEqual(
            restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent?.sessionId,
            "codex-019df0a1-6"
        )

        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .promptIdle)

        XCTAssertNil(restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.agent)
    }
}
