import XCTest
@testable import cmux_ios

@MainActor
final class CmxWorkspacePresentationTests: XCTestCase {
    func testDefaultStoreStartsWithoutDemoWorkspaces() {
        let store = CmxConnectionStore()

        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertTrue(store.visibleWorkspaces(matching: "").isEmpty)
        XCTAssertEqual(store.terminalDetailPresentation, .notConnected)
    }

    func testVisibleWorkspacesSortsMostRecentAcrossMachinesRegardlessPinned() {
        let store = CmxConnectionStore()
        store.applyHiveDiscoverySnapshot(Self.presentationSnapshot())
        store.workspaces[0].pinned = true
        store.workspaces[0].lastActivity = Date(timeIntervalSince1970: 1_777_680_000)
        store.workspaces[1].pinned = false
        store.workspaces[1].lastActivity = Date(timeIntervalSince1970: 1_777_680_600)

        let workspaces = store.visibleWorkspaces(matching: "")

        XCTAssertEqual(workspaces.map(\.title), ["agent runs", "main"])
    }

    func testVisibleWorkspacesSearchesNodeAndPreviewText() {
        let store = CmxConnectionStore()
        store.applyHiveDiscoverySnapshot(Self.presentationSnapshot())

        XCTAssertEqual(store.visibleWorkspaces(matching: "standby").map(\.title), ["agent runs"])
        XCTAssertEqual(store.visibleWorkspaces(matching: "Ghostty").map(\.title), ["main"])
    }

    func testVisibleWorkspacesCanFilterAndHideUnavailableMachines() {
        let store = CmxConnectionStore(
            hiddenUnavailableNodeStore: MemoryHiddenUnavailableNodeStore(),
            startHiveDiscoveryOnInit: false
        )
        let baseSnapshot = Self.presentationSnapshot()
        var nodes = baseSnapshot.nodes
        nodes[1].isOnline = false
        let snapshot = CmxHiveDiscoverySnapshot(nodes: nodes, workspaces: baseSnapshot.workspaces)
        store.applyHiveDiscoverySnapshot(snapshot)

        XCTAssertEqual(store.visibleWorkspaces(matching: "", filter: .all).map(\.title), ["main", "agent runs"])
        XCTAssertEqual(store.visibleWorkspaces(matching: "", filter: .online).map(\.title), ["main"])
        XCTAssertEqual(store.visibleWorkspaces(matching: "", filter: .offline).map(\.title), ["agent runs"])

        store.hideUnavailableWorkspaces(from: snapshot.nodes[1])

        XCTAssertEqual(store.visibleWorkspaces(matching: "", filter: .all).map(\.title), ["main"])
        XCTAssertEqual(store.visibleWorkspaces(matching: "", filter: .hiddenUnavailable).map(\.title), ["agent runs"])

        store.showUnavailableWorkspaces(from: snapshot.nodes[1])

        XCTAssertEqual(store.visibleWorkspaces(matching: "", filter: .all).map(\.title), ["main", "agent runs"])
    }

    func testNativeSnapshotPopulatesRustOwnedWorkspaceState() {
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
        XCTAssertTrue(store.canRenderSelectedTerminal)
        XCTAssertEqual(store.terminalDetailPresentation, .notConnected)
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
        XCTAssertEqual(store.terminalDetailPresentation, .notConnected)
    }

    func testInactiveWorkspaceWithKnownTerminalsPresentsLoadingUntilNativeSnapshotActivatesIt() {
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
                    CmxNativeWorkspaceInfo(
                        id: 12,
                        title: "agent runs",
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
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41
            )
        )

        store.select(workspaceID: 12)

        XCTAssertEqual(store.selectedWorkspace.title, "agent runs")
        XCTAssertFalse(store.canRenderSelectedTerminal)
        XCTAssertEqual(store.terminalDetailPresentation, .notConnected)
    }

    func testDisconnectedStorePresentsNotConnectedEvenWithCachedTerminalState() {
        let sessionFactory = WorkspacePresentationTerminalSessionFactory()
        let store = CmxConnectionStore(
            terminalSessionFactory: sessionFactory,
            launchTicket: nil,
            launchAutoconnect: false
        )
        store.ticketText = Self.directTicketJSON()

        store.connect()
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .welcome(serverVersion: "test", sessionID: "session")
        )
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(Self.nativeSnapshot(title: "main"))
        )
        XCTAssertEqual(store.terminalDetailPresentation, .loadingTerminal)

        store.disconnect()

        XCTAssertFalse(store.workspaces.isEmpty)
        XCTAssertTrue(store.canRenderSelectedTerminal)
        XCTAssertEqual(store.terminalDetailPresentation, .notConnected)
    }

    func testEmptyNativeSnapshotDoesNotReplaceExistingWorkspaceList() {
        let store = CmxConnectionStore()
        store.applyNativeSnapshot(Self.nativeSnapshot(title: "main"))

        store.applyNativeSnapshot(Self.emptyNativeSnapshot())

        XCTAssertEqual(store.workspaces.map(\.title), ["main"])
        XCTAssertEqual(store.selectedWorkspaceID, 11)
        XCTAssertFalse(store.isAwaitingInitialWorkspaceSnapshot)
    }

    func testConnectedStoreAwaitsNonEmptyInitialWorkspaceSnapshot() {
        let sessionFactory = WorkspacePresentationTerminalSessionFactory()
        let store = CmxConnectionStore(
            terminalSessionFactory: sessionFactory,
            launchTicket: nil,
            launchAutoconnect: false
        )
        store.ticketText = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": { "id": "endpoint-public-key", "addrs": [] },
          "auth": { "mode": "direct" }
        }
        """

        store.connect()
        XCTAssertTrue(store.isAwaitingInitialWorkspaceSnapshot)

        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(Self.emptyNativeSnapshot())
        )
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertTrue(store.isAwaitingInitialWorkspaceSnapshot)
        XCTAssertEqual(store.terminalDetailPresentation, .loadingWorkspaces)

        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(Self.nativeSnapshot(title: "main"))
        )
        XCTAssertEqual(store.workspaces.map(\.title), ["main"])
        XCTAssertFalse(store.isAwaitingInitialWorkspaceSnapshot)
        XCTAssertEqual(store.terminalDetailPresentation, .loadingTerminal)
    }

    private static func nativeSnapshot(title: String) -> CmxNativeSnapshot {
        CmxNativeSnapshot(
            workspaces: [
                CmxNativeWorkspaceInfo(
                    id: 11,
                    title: title,
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
                    CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                ],
                active: 0,
                activeTabID: 41
            ),
            focusedPanelID: 31,
            focusedTabID: 41
        )
    }

    private static func emptyNativeSnapshot() -> CmxNativeSnapshot {
        CmxNativeSnapshot(
            workspaces: [],
            activeWorkspace: 0,
            activeWorkspaceID: 0,
            spaces: [],
            activeSpace: 0,
            activeSpaceID: 0,
            panels: .leaf(panelID: 0, tabs: [], active: 0, activeTabID: 0),
            focusedPanelID: 0,
            focusedTabID: 0
        )
    }

    private static func directTicketJSON() -> String {
        """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": { "id": "endpoint-public-key", "addrs": [] },
          "auth": { "mode": "direct" }
        }
        """
    }

    private static func presentationSnapshot() -> CmxHiveDiscoverySnapshot {
        let referenceDate = Date(timeIntervalSince1970: 1_777_680_000)
        return CmxHiveDiscoverySnapshot(
            nodes: [
                CmxHiveNode(
                    id: 1,
                    rawID: "macbook",
                    name: "MacBook Pro",
                    subtitle: "local dev node",
                    symbolName: "laptopcomputer",
                    platform: .macOS,
                    isOnline: true
                ),
                CmxHiveNode(
                    id: 2,
                    rawID: "mac-mini",
                    name: "Mac mini",
                    subtitle: "hive standby",
                    symbolName: "macmini",
                    platform: .macOS,
                    isOnline: true
                ),
            ],
            workspaces: [
                CmxWorkspace(
                    id: 1,
                    nodeID: 1,
                    title: "main",
                    preview: "cmx tui attached over Ghostty",
                    lastActivity: referenceDate.addingTimeInterval(-120),
                    unread: true,
                    pinned: true,
                    spaces: [
                        CmxSpace(
                            id: 10,
                            title: "space-1",
                            terminals: [
                                CmxTerminal(id: 100, title: "cmx", size: .phoneDefault, rows: []),
                            ]
                        ),
                    ]
                ),
                CmxWorkspace(
                    id: 2,
                    nodeID: 2,
                    title: "agent runs",
                    preview: "review pane waiting on sync",
                    lastActivity: referenceDate.addingTimeInterval(-3_600),
                    unread: false,
                    pinned: false,
                    spaces: [
                        CmxSpace(
                            id: 20,
                            title: "review",
                            terminals: [
                                CmxTerminal(id: 200, title: "status", size: .phoneDefault, rows: []),
                            ]
                        ),
                    ]
                ),
            ]
        )
    }
}

@MainActor
private final class WorkspacePresentationTerminalSessionFactory: CmxTerminalSessionMaking {
    let session = WorkspacePresentationTerminalSession()

    func makeSession(
        rawTicket _: String,
        ticket _: CmxBridgeTicket,
        pairingSecret _: String?,
        stackAuthSession _: CmxStackAuthSession?
    ) throws -> any CmxTerminalSession {
        session
    }
}

@MainActor
private final class WorkspacePresentationTerminalSession: CmxTerminalSession {
    weak var delegate: CmxTerminalSessionDelegate?

    func start(viewport _: CmxWireViewport) {}

    func sendInput(_: Data, terminalID _: UInt64) {}

    func sendResize(_: CmxWireViewport, terminalID _: UInt64) {}

    func sendNativeLayout(_: [CmxWireTerminalViewport]) {}

    func requestPtyReplay(terminalID _: UInt64) {}

    func sendCommand(_: CmxClientCommand) {}

    func disconnect() {}
}

private final class MemoryHiddenUnavailableNodeStore: CmxHiddenUnavailableNodeStoring {
    var nodeIDs: Set<UInt64> = []

    func loadHiddenNodeIDs() throws -> Set<UInt64> {
        nodeIDs
    }

    func saveHiddenNodeIDs(_ nodeIDs: Set<UInt64>) throws {
        self.nodeIDs = nodeIDs
    }
}
