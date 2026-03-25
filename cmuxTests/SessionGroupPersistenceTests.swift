import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SessionGroupPersistenceTests: XCTestCase {

    // MARK: - Snapshot Round-Trip

    func testWorkspaceGroupSnapshotRoundTrip() throws {
        let snapshot = SessionWorkspaceGroupSnapshot(
            title: "Project",
            color: "#FF0000",
            isCollapsed: true,
            isPinned: false,
            workingDirectory: "/tmp/project",
            items: [
                .workspace(workspaceIndex: 0),
                .workspace(workspaceIndex: 2),
                .group(SessionWorkspaceGroupSnapshot(
                    title: "Sub",
                    color: nil,
                    isCollapsed: false,
                    isPinned: false,
                    workingDirectory: "/tmp/project/sub",
                    items: [.workspace(workspaceIndex: 1)]
                ))
            ]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionWorkspaceGroupSnapshot.self, from: data)
        XCTAssertEqual(decoded.title, "Project")
        XCTAssertEqual(decoded.color, "#FF0000")
        XCTAssertTrue(decoded.isCollapsed)
        XCTAssertFalse(decoded.isPinned)
        XCTAssertEqual(decoded.workingDirectory, "/tmp/project")
        XCTAssertEqual(decoded.items.count, 3)
    }

    func testSidebarLayoutSnapshotRoundTrip() throws {
        let layout = SessionSidebarLayoutSnapshot(items: [
            .standalone(workspaceIndex: 0),
            .group(SessionWorkspaceGroupSnapshot(
                title: "G",
                color: nil,
                isCollapsed: false,
                isPinned: true,
                workingDirectory: "/tmp",
                items: [.workspace(workspaceIndex: 1)]
            ))
        ])
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(SessionSidebarLayoutSnapshot.self, from: data)
        XCTAssertEqual(decoded.items.count, 2)
    }

    func testSidebarItemSnapshotStandaloneRoundTrip() throws {
        let item = SessionSidebarItemSnapshot.standalone(workspaceIndex: 5)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(SessionSidebarItemSnapshot.self, from: data)
        if case .standalone(let index) = decoded {
            XCTAssertEqual(index, 5)
        } else {
            XCTFail("Expected standalone")
        }
    }

    func testGroupItemSnapshotWorkspaceRoundTrip() throws {
        let item = SessionGroupItemSnapshot.workspace(workspaceIndex: 3)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(SessionGroupItemSnapshot.self, from: data)
        if case .workspace(let index) = decoded {
            XCTAssertEqual(index, 3)
        } else {
            XCTFail("Expected workspace")
        }
    }

    // MARK: - Backward Compatibility

    func testBackwardCompatibilityWithNoSidebarLayout() throws {
        let json = """
        {"selectedWorkspaceIndex": 0, "workspaces": []}
        """
        let snapshot = try JSONDecoder().decode(
            SessionTabManagerSnapshot.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertNil(snapshot.sidebarLayout)
    }

    func testTabManagerSnapshotWithSidebarLayoutRoundTrip() throws {
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [],
            sidebarLayout: SessionSidebarLayoutSnapshot(items: [
                .standalone(workspaceIndex: 0),
                .group(SessionWorkspaceGroupSnapshot(
                    title: "Test",
                    color: "#00FF00",
                    isCollapsed: false,
                    isPinned: false,
                    workingDirectory: "/tmp",
                    items: [.workspace(workspaceIndex: 1)]
                ))
            ])
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: data)
        XCTAssertNotNil(decoded.sidebarLayout)
        XCTAssertEqual(decoded.sidebarLayout?.items.count, 2)
    }

    // MARK: - New Model Fields

    func testWorkspaceSnapshotChildIndicesRoundTrip() throws {
        let snapshot = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            isPinned: false,
            currentDirectory: "/tmp",
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            childWorkspaceIndices: [1, 2],
            isCollapsed: true
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded.childWorkspaceIndices, [1, 2])
        XCTAssertEqual(decoded.isCollapsed, true)
    }

    func testWorkspaceSnapshotChildIndicesNilByDefault() throws {
        let json = """
        {"processTitle":"T","isPinned":false,"currentDirectory":"/tmp","layout":{"type":"pane","pane":{"panelIds":[]}},"panels":[],"statusEntries":[],"logEntries":[]}
        """
        let decoded = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertNil(decoded.childWorkspaceIndices)
        XCTAssertNil(decoded.isCollapsed)
    }

    func testTabManagerSnapshotTopLevelIndicesRoundTrip() throws {
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [],
            topLevelWorkspaceIndices: [0, 2, 1]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: data)
        XCTAssertEqual(decoded.topLevelWorkspaceIndices, [0, 2, 1])
    }

    // MARK: - Nested Group Snapshot

    func testNestedGroupSnapshotRoundTrip() throws {
        let nested = SessionWorkspaceGroupSnapshot(
            title: "Inner",
            color: nil,
            isCollapsed: true,
            isPinned: false,
            workingDirectory: "/tmp/inner",
            items: [.workspace(workspaceIndex: 2)]
        )
        let outer = SessionWorkspaceGroupSnapshot(
            title: "Outer",
            color: "#AABBCC",
            isCollapsed: false,
            isPinned: true,
            workingDirectory: "/tmp/outer",
            items: [
                .workspace(workspaceIndex: 0),
                .group(nested),
                .workspace(workspaceIndex: 1)
            ]
        )
        let data = try JSONEncoder().encode(outer)
        let decoded = try JSONDecoder().decode(SessionWorkspaceGroupSnapshot.self, from: data)
        XCTAssertEqual(decoded.title, "Outer")
        XCTAssertTrue(decoded.isPinned)
        XCTAssertEqual(decoded.items.count, 3)

        // Verify nested group decoded correctly
        if case .group(let innerDecoded) = decoded.items[1] {
            XCTAssertEqual(innerDecoded.title, "Inner")
            XCTAssertTrue(innerDecoded.isCollapsed)
            XCTAssertEqual(innerDecoded.items.count, 1)
        } else {
            XCTFail("Expected nested group at index 1")
        }
    }
}
