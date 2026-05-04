import XCTest
@testable import cmux_ios

@MainActor
final class CmxWorkspacePresentationTests: XCTestCase {
    func testVisibleWorkspacesPreferPinnedThenRecent() {
        let store = CmxConnectionStore()

        let workspaces = store.visibleWorkspaces(matching: "")

        XCTAssertEqual(workspaces.map(\.title), ["main", "agent runs"])
    }

    func testVisibleWorkspacesSearchesNodeAndPreviewText() {
        let store = CmxConnectionStore()

        XCTAssertEqual(store.visibleWorkspaces(matching: "standby").map(\.title), ["agent runs"])
        XCTAssertEqual(store.visibleWorkspaces(matching: "Ghostty").map(\.title), ["main"])
    }

    func testNativeSnapshotReplacesDemoStateWithRustOwnedWorkspaceState() {
        let store = CmxConnectionStore()

        store.applyNativeSnapshot(
            CmxNativeSnapshot(
                workspaces: [
                    CmxNativeWorkspaceInfo(
                        id: 11,
                        title: "rust-main",
                        spaceCount: 1,
                        tabCount: 2,
                        terminalCount: 2,
                        pinned: true,
                        color: nil
                    ),
                ],
                activeWorkspace: 0,
                activeWorkspaceID: 11,
                spaces: [
                    CmxNativeSpaceInfo(id: 21, title: "dev", paneCount: 1, terminalCount: 2),
                ],
                activeSpace: 0,
                activeSpaceID: 21,
                panels: .leaf(
                    panelID: 31,
                    tabs: [
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                        CmxNativeTabInfo(id: 42, title: "logs", hasActivity: true, bellCount: 1),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41
            )
        )

        XCTAssertEqual(store.workspaces.map(\.title), ["rust-main"])
        XCTAssertEqual(store.selectedWorkspaceID, 11)
        XCTAssertEqual(store.selectedSpaceID, 21)
        XCTAssertEqual(store.selectedSpace.terminals.map(\.id), [41, 42])
        XCTAssertEqual(store.selectedTerminal.title, "shell")
    }

    func testNativeSnapshotAllowsZeroValuedRustTabID() {
        let store = CmxConnectionStore()

        store.applyNativeSnapshot(
            CmxNativeSnapshot(
                workspaces: [
                    CmxNativeWorkspaceInfo(
                        id: 11,
                        title: "main",
                        spaceCount: 1,
                        tabCount: 1,
                        terminalCount: 1,
                        pinned: false,
                        color: nil
                    ),
                ],
                activeWorkspace: 0,
                activeWorkspaceID: 11,
                spaces: [
                    CmxNativeSpaceInfo(id: 21, title: "space-1", paneCount: 1, terminalCount: 1),
                ],
                activeSpace: 0,
                activeSpaceID: 21,
                panels: .leaf(
                    panelID: 31,
                    tabs: [
                        CmxNativeTabInfo(id: 0, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 0
                ),
                focusedPanelID: 31,
                focusedTabID: 0
            )
        )
        store.updateTerminalSize(terminalID: 0, size: CmxTerminalSize(cols: 111, rows: 33))

        XCTAssertEqual(store.selectedTerminal.id, 0)
        XCTAssertEqual(store.terminalSize(for: 0), CmxTerminalSize(cols: 111, rows: 33))
    }

    func testNativeSnapshotWithNoSpacesOrTabsUsesPlaceholdersInsteadOfStaleSelection() {
        let store = CmxConnectionStore()

        store.applyNativeSnapshot(
            CmxNativeSnapshot(
                workspaces: [
                    CmxNativeWorkspaceInfo(
                        id: 11,
                        title: "empty",
                        spaceCount: 0,
                        tabCount: 0,
                        terminalCount: 0,
                        pinned: false,
                        color: nil
                    ),
                ],
                activeWorkspace: 0,
                activeWorkspaceID: 11,
                spaces: [],
                activeSpace: 0,
                activeSpaceID: 21,
                panels: .leaf(panelID: 31, tabs: [], active: 0, activeTabID: 41),
                focusedPanelID: 31,
                focusedTabID: 41
            )
        )

        XCTAssertEqual(store.selectedWorkspace.title, "empty")
        XCTAssertTrue(store.selectedSpace.terminals.isEmpty)
        XCTAssertEqual(store.selectedTerminal.title, "cmx")
        XCTAssertEqual(store.terminalSize(for: store.selectedTerminal.id), .phoneDefault)
    }
}
