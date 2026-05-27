import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AgentSessionSocketSurfaceTests: XCTestCase {
    func testPanelTypeParserAcceptsAgentSessionSpellings() {
        let controller = TerminalController.shared

        for rawValue in ["agentSession", "agent-session", "agent_session", "agent session", "agentsession"] {
            XCTAssertEqual(
                controller.v2PanelType(["type": rawValue], "type"),
                .agentSession,
                "Expected \(rawValue) to parse as an agent session surface"
            )
        }
    }

    func testWorkspaceCreatesAgentSessionSurfaceWithProviderAndRenderer() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)

        let panel = try XCTUnwrap(
            workspace.newAgentSessionSurface(
                inPane: paneId,
                providerID: .opencode,
                rendererKind: .solid,
                workingDirectory: "/tmp",
                focus: true
            )
        )

        XCTAssertEqual(panel.panelType, .agentSession)
        XCTAssertEqual(panel.initialProviderID, .opencode)
        XCTAssertEqual(panel.rendererKind, .solid)
        XCTAssertEqual(panel.workingDirectory, "/tmp")
        XCTAssertEqual(workspace.panelDirectories[panel.id], "/tmp")
        XCTAssertEqual(workspace.focusedPanelId, panel.id)
    }

    func testWorkspaceSessionSnapshotPersistsAgentSessionWorkingDirectory() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)

        let panel = try XCTUnwrap(
            workspace.newAgentSessionSurface(
                inPane: paneId,
                providerID: .codex,
                rendererKind: .react,
                workingDirectory: "/tmp/cmux-agent-session-cwd",
                focus: true
            )
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panel.id })
        XCTAssertEqual(panelSnapshot.directory, "/tmp/cmux-agent-session-cwd")
        XCTAssertEqual(panelSnapshot.agentSession?.workingDirectory, "/tmp/cmux-agent-session-cwd")
    }
}
