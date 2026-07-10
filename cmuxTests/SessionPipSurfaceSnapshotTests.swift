import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SessionPipSurfaceSnapshotTests: XCTestCase {
    func testAppSessionSnapshotRoundTripsPipSurfaces() throws {
        let homeWorkspaceId = UUID()
        let panelId = UUID()
        var snapshot = Self.makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.windows[0].tabManager.workspaces[0].workspaceId = homeWorkspaceId
        snapshot.pipSurfaces = [
            SessionPipSurfaceSnapshot(
                panel: Self.pipTerminalPanelSnapshot(id: panelId),
                frame: SessionRectSnapshot(x: 100, y: 120, width: 480, height: 320),
                homeWorkspaceId: homeWorkspaceId
            )
        ]

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        let pip = try XCTUnwrap(decoded.pipSurfaces?.first)
        XCTAssertEqual(pip.panel.id, panelId)
        XCTAssertEqual(pip.homeWorkspaceId, homeWorkspaceId)
        XCTAssertEqual(pip.frame, SessionRectSnapshot(x: 100, y: 120, width: 480, height: 320))

        let workspace = try XCTUnwrap(decoded.restoringPipSurfacesAsWorkspaceTabs().windows.first?.tabManager.workspaces.first)
        XCTAssertTrue(workspace.panels.contains(where: { $0.id == panelId }))
        guard case .pane(let pane) = workspace.layout else {
            XCTFail("expected pane layout")
            return
        }
        XCTAssertEqual(pane.panelIds, [panelId])
        XCTAssertEqual(pane.selectedPanelId, panelId)
    }

    func testAppSessionSnapshotDecodesWithoutPipSurfacesField() throws {
        let snapshot = Self.makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"pipSurfaces\""))

        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        XCTAssertNil(decoded.pipSurfaces)
    }

    private static func makeSnapshot(version: Int) -> AppSessionSnapshot {
        let workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Restored",
            customColor: nil,
            isPinned: true,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )

        let tabManager = SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspace])
        let window = SessionWindowSnapshot(
            frame: SessionRectSnapshot(x: 10, y: 20, width: 900, height: 700),
            display: SessionDisplaySnapshot(
                displayID: 42,
                frame: SessionRectSnapshot(x: 0, y: 0, width: 1920, height: 1200),
                visibleFrame: SessionRectSnapshot(x: 0, y: 25, width: 1920, height: 1175)
            ),
            tabManager: tabManager,
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )
        return AppSessionSnapshot(version: version, createdAt: Date().timeIntervalSince1970, windows: [window])
    }

    private static func pipTerminalPanelSnapshot(id: UUID) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: .terminal,
            title: "PiP Terminal",
            directory: "/tmp",
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            terminal: SessionTerminalPanelSnapshot(workingDirectory: "/tmp")
        )
    }
}
