import Foundation
import XCTest
@testable import cmux_ios

final class CmxHiveDiscoveryClientTests: XCTestCase {
    override func tearDown() {
        CmxHiveDiscoveryURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchHiveUsesStackHeadersAndDecodesNestedWorkspaces() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CmxHiveDiscoveryURLProtocol.self]
        let client = CmxHiveDiscoveryClient(urlSession: URLSession(configuration: configuration))

        CmxHiveDiscoveryURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Stack-Refresh-Token"), "refresh")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Cmux-Team-Id"), "team-alpha")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    """
                    {
                      "nodes": [
                        {
                          "id": "macbook-lawrence",
                          "name": "Lawrence MacBook Pro",
                          "subtitle": "online over iroh",
                          "kind": "macbook",
                          "is_online": true,
                          "attach_ticket": "{\\"version\\":1,\\"alpn\\":\\"/cmux/cmx/3\\",\\"endpoint\\":{\\"id\\":\\"endpoint-public-key\\",\\"addrs\\":[]},\\"auth\\":{\\"mode\\":\\"direct\\"}}",
                          "workspaces": [
                            {
                              "id": "workspace-main",
                              "title": "main",
                              "preview": "lawrence in ~/fun/cmux-cli",
                              "last_activity_unix": 1777680000,
                              "unread": true,
                              "pinned": true,
                              "spaces": [
                                {
                                  "id": "space-dev",
                                  "title": "dev",
                                  "terminals": [
                                    {
                                      "id": "terminal-shell",
                                      "title": "shell",
                                      "cols": 120,
                                      "rows": 40,
                                      "output_rows": ["lawrence in ~/fun/cmux-cli"]
                                    }
                                  ]
                                }
                              ]
                            }
                          ]
                        }
                      ]
                    }
                    """.utf8
                )
            )
        }

        let snapshot = try await client.fetchHive(
            endpoint: URL(string: "https://rivet.example/hive")!,
            stackSession: CmxStackAuthSession(refreshToken: "refresh", accessToken: "access"),
            teamID: "team-alpha"
        )

        XCTAssertEqual(snapshot.nodes.map(\.name), ["Lawrence MacBook Pro"])
        XCTAssertEqual(snapshot.nodes.first?.platform, .macOS)
        XCTAssertEqual(snapshot.nodes.first?.symbolName, "laptopcomputer")
        XCTAssertTrue(snapshot.nodes.first?.attachTicket?.contains(#""mode":"direct""#) ?? false)
        XCTAssertEqual(snapshot.workspaces.map(\.title), ["main"])
        XCTAssertEqual(snapshot.workspaces.first?.nodeID, snapshot.nodes.first?.id)
        XCTAssertEqual(snapshot.workspaces.first?.localWorkspaceID, "workspace-main")
        XCTAssertEqual(snapshot.workspaces.first?.spaces.first?.terminals.first?.size, CmxTerminalSize(cols: 120, rows: 40))
    }

    func testFetchHiveRejectsInvalidEndpointBeforeNetworkRequest() async {
        let client = CmxHiveDiscoveryClient(urlSession: .shared)

        do {
            _ = try await client.fetchHive(
                endpoint: URL(string: "file:///tmp/hive.json")!,
                stackSession: CmxStackAuthSession(refreshToken: "refresh", accessToken: "access"),
                teamID: nil
            )
            XCTFail("expected invalid endpoint")
        } catch {
            XCTAssertEqual(error as? CmxHiveDiscoveryError, .invalidEndpoint)
        }
    }

    func testFetchHiveKeepsSameLocalWorkspaceIDsFromDifferentNodesDistinct() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CmxHiveDiscoveryURLProtocol.self]
        let client = CmxHiveDiscoveryClient(urlSession: URLSession(configuration: configuration))

        CmxHiveDiscoveryURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    """
                    {
                      "nodes": [
                        {
                          "id": "macbook",
                          "name": "MacBook Pro",
                          "kind": "macbook",
                          "is_online": true,
                          "workspaces": [
                            {
                              "id": "workspace-main",
                              "title": "main",
                              "spaces": [
                                {
                                  "id": "space-dev",
                                  "title": "dev",
                                  "terminals": [{ "id": "terminal-shell", "title": "shell" }]
                                }
                              ]
                            }
                          ]
                        },
                        {
                          "id": "mac-mini",
                          "name": "Mac mini",
                          "kind": "macmini",
                          "is_online": true,
                          "workspaces": [
                            {
                              "id": "workspace-main",
                              "title": "main",
                              "spaces": [
                                {
                                  "id": "space-dev",
                                  "title": "dev",
                                  "terminals": [{ "id": "terminal-shell", "title": "shell" }]
                                }
                              ]
                            }
                          ]
                        }
                      ]
                    }
                    """.utf8
                )
            )
        }

        let snapshot = try await client.fetchHive(
            endpoint: URL(string: "https://rivet.example/hive")!,
            stackSession: CmxStackAuthSession(refreshToken: "refresh", accessToken: "access"),
            teamID: nil
        )

        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(Set(snapshot.workspaces.map(\.id)).count, 2)
        XCTAssertEqual(Set(snapshot.workspaces.flatMap(\.spaces).map(\.id)).count, 2)
        XCTAssertEqual(Set(snapshot.workspaces.flatMap(\.spaces).flatMap(\.terminals).map(\.id)).count, 2)
    }

    func testFetchHiveTreatsRestoringNodeAsUnavailable() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CmxHiveDiscoveryURLProtocol.self]
        let client = CmxHiveDiscoveryClient(urlSession: URLSession(configuration: configuration))

        CmxHiveDiscoveryURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    """
                    {
                      "nodes": [
                        {
                          "id": "macbook",
                          "name": "MacBook Pro",
                          "kind": "macbook",
                          "is_online": true,
                          "restore_state": "restoring",
                          "workspaces": [
                            {
                              "id": "workspace-main",
                              "title": "main",
                              "spaces": []
                            }
                          ]
                        }
                      ]
                    }
                    """.utf8
                )
            )
        }

        let snapshot = try await client.fetchHive(
            endpoint: URL(string: "https://rivet.example/hive")!,
            stackSession: CmxStackAuthSession(refreshToken: "refresh", accessToken: "access"),
            teamID: nil
        )

        XCTAssertEqual(snapshot.nodes.first?.isOnline, false)
        XCTAssertEqual(snapshot.workspaces.map(\.title), ["main"])
    }
}

@MainActor
final class CmxHiveDiscoveryStoreTests: XCTestCase {
    func testSignedInHiveDiscoveryReplacesDemoWorkspaceInbox() async {
        let authStore = MemoryHiveAuthSessionStore(
            session: CmxStackAuthSession(refreshToken: "refresh", accessToken: "access")
        )
        let discovery = RecordingHiveDiscoveryClient(
            snapshot: CmxHiveDiscoverySnapshot(
                nodes: [
                    CmxHiveNode(
                        id: 41,
                        rawID: "mac-mini",
                        name: "Mac mini",
                        subtitle: "hive node",
                        symbolName: "macmini",
                        platform: .macOS,
                        isOnline: true
                    ),
                ],
                workspaces: [
                    CmxWorkspace(
                        id: 99,
                        nodeID: 41,
                        title: "prod-main",
                        preview: "shared shell",
                        lastActivity: Date(timeIntervalSince1970: 1_777_680_000),
                        unread: false,
                        pinned: true,
                        spaces: [
                            CmxSpace(
                                id: 199,
                                title: "dev",
                                terminals: [
                                    CmxTerminal(
                                        id: 299,
                                        title: "shell",
                                        size: CmxTerminalSize(cols: 101, rows: 31),
                                        rows: ["lawrence in ~/fun/cmux-cli"]
                                    ),
                                ]
                            ),
                        ]
                    ),
                ]
            )
        )

        let store = CmxConnectionStore(
            authSessionStore: authStore,
            pairingSecretClient: RecordingHivePairingSecretClient(),
            hiveDiscoveryClient: discovery,
            hiveControlClient: RecordingHiveControlClient(
                teamsSnapshot: CmxHiveTeamsSnapshot(
                    teams: [CmxHiveTeam(id: "team-alpha", displayName: "Alpha Team", isPersonal: false)],
                    defaultTeamID: "personal:user-1",
                    selectedTeamID: nil
                )
            ),
            hiveTeamPreferenceStore: MemoryHiveTeamPreferenceStore(),
            hiveDiscoveryCacheStore: MemoryHiveDiscoveryCacheStore(),
            hiveDiscoveryEndpoint: URL(string: "https://rivet.example/hive")!,
            terminalSessionFactory: RecordingHiveTerminalSessionFactory(),
            startHiveDiscoveryOnInit: false
        )
        let refreshTask = store.refreshHiveDiscoveryIfPossible()
        await refreshTask?.value

        XCTAssertEqual(discovery.fetchCount, 1)
        XCTAssertEqual(discovery.lastEndpoint?.absoluteString, "https://rivet.example/hive")
        XCTAssertEqual(discovery.lastStackSession, CmxStackAuthSession(refreshToken: "refresh", accessToken: "access"))
        XCTAssertEqual(discovery.lastTeamID, "personal:user-1")
        XCTAssertEqual(store.nodes.map(\.name), ["Mac mini"])
        XCTAssertEqual(store.workspaces.map(\.title), ["prod-main"])
        XCTAssertEqual(store.selectedWorkspaceID, 99)
        XCTAssertEqual(store.selectedSpaceID, 199)
        XCTAssertEqual(store.selectedTerminalID, 299)
    }

    func testHiveDiscoveryUsesExplicitSelectedTeam() async {
        let authStore = MemoryHiveAuthSessionStore(
            session: CmxStackAuthSession(refreshToken: "refresh", accessToken: "access")
        )
        let discovery = RecordingHiveDiscoveryClient(snapshot: CmxHiveDiscoverySnapshot(nodes: [], workspaces: []))
        let control = RecordingHiveControlClient(
            teamsSnapshot: CmxHiveTeamsSnapshot(
                teams: [
                    CmxHiveTeam(id: "personal:user-1", displayName: "Personal", isPersonal: true),
                    CmxHiveTeam(id: "team-alpha", displayName: "Alpha Team", isPersonal: false),
                ],
                defaultTeamID: "personal:user-1",
                selectedTeamID: nil
            )
        )

        let store = CmxConnectionStore(
            authSessionStore: authStore,
            pairingSecretClient: RecordingHivePairingSecretClient(),
            hiveDiscoveryClient: discovery,
            hiveControlClient: control,
            hiveTeamPreferenceStore: MemoryHiveTeamPreferenceStore(selectedTeamID: "team-alpha"),
            hiveDiscoveryCacheStore: MemoryHiveDiscoveryCacheStore(),
            hiveDiscoveryEndpoint: URL(string: "https://rivet.example/hive")!,
            terminalSessionFactory: RecordingHiveTerminalSessionFactory(),
            startHiveDiscoveryOnInit: false
        )
        let refreshTask = store.refreshHiveDiscoveryIfPossible()
        await refreshTask?.value

        XCTAssertEqual(control.fetchTeamsCount, 1)
        XCTAssertEqual(discovery.lastTeamID, "team-alpha")
        XCTAssertEqual(store.effectiveHiveTeamID, "team-alpha")
    }

    func testHiveDiscoveryRestoresCachedInboxForFastLaunch() {
        let cache = MemoryHiveDiscoveryCacheStore(
            payload: CmxHiveDiscoveryCachePayload(
                teams: [CmxHiveTeam(id: "personal:user-1", displayName: "Personal", isPersonal: true)],
                defaultTeamID: "personal:user-1",
                selectedTeamID: nil,
                nodes: [
                    CmxHiveNode(
                        id: 41,
                        rawID: "mac-mini",
                        name: "Mac mini",
                        subtitle: "cached",
                        symbolName: "macmini",
                        platform: .macOS,
                        isOnline: false
                    ),
                ],
                workspaces: [
                    CmxWorkspace(
                        id: 99,
                        nodeID: 41,
                        title: "cached-main",
                        preview: "last seen",
                        lastActivity: Date(timeIntervalSince1970: 1_777_680_000),
                        unread: false,
                        pinned: false,
                        spaces: []
                    ),
                ],
                cachedAt: Date(timeIntervalSince1970: 1_777_680_000)
            )
        )

        let store = CmxConnectionStore(
            authSessionStore: MemoryHiveAuthSessionStore(),
            pairingSecretClient: RecordingHivePairingSecretClient(),
            hiveDiscoveryClient: RecordingHiveDiscoveryClient(snapshot: CmxHiveDiscoverySnapshot(nodes: [], workspaces: [])),
            hiveControlClient: RecordingHiveControlClient(
                teamsSnapshot: CmxHiveTeamsSnapshot(teams: [], defaultTeamID: nil, selectedTeamID: nil)
            ),
            hiveDiscoveryCacheStore: cache,
            hiveDiscoveryEndpoint: URL(string: "https://rivet.example/hive")!,
            terminalSessionFactory: RecordingHiveTerminalSessionFactory(),
            startHiveDiscoveryOnInit: false
        )

        XCTAssertEqual(store.nodes.map(\.name), ["Mac mini"])
        XCTAssertEqual(store.workspaces.map(\.title), ["cached-main"])
        XCTAssertEqual(store.selectedWorkspaceID, 99)
    }

    func testHiveDiscoverySavesCacheAfterRefresh() async {
        let authStore = MemoryHiveAuthSessionStore(
            session: CmxStackAuthSession(refreshToken: "refresh", accessToken: "access")
        )
        let cache = MemoryHiveDiscoveryCacheStore()
        let node = CmxHiveNode(
            id: 41,
            rawID: "mac-mini",
            name: "Mac mini",
            subtitle: "hive node",
            symbolName: "macmini",
            platform: .macOS,
            isOnline: true
        )
        let workspace = CmxWorkspace(
            id: 99,
            nodeID: 41,
            title: "prod-main",
            preview: "shared shell",
            lastActivity: Date(timeIntervalSince1970: 1_777_680_000),
            unread: false,
            pinned: false,
            spaces: []
        )
        let store = CmxConnectionStore(
            authSessionStore: authStore,
            pairingSecretClient: RecordingHivePairingSecretClient(),
            hiveDiscoveryClient: RecordingHiveDiscoveryClient(
                snapshot: CmxHiveDiscoverySnapshot(nodes: [node], workspaces: [workspace])
            ),
            hiveControlClient: RecordingHiveControlClient(
                teamsSnapshot: CmxHiveTeamsSnapshot(
                    teams: [CmxHiveTeam(id: "personal:user-1", displayName: "Personal", isPersonal: true)],
                    defaultTeamID: "personal:user-1",
                    selectedTeamID: nil
                )
            ),
            hiveDiscoveryCacheStore: cache,
            hiveDiscoveryEndpoint: URL(string: "https://rivet.example/hive")!,
            terminalSessionFactory: RecordingHiveTerminalSessionFactory(),
            startHiveDiscoveryOnInit: false
        )

        let refreshTask = store.refreshHiveDiscoveryIfPossible()
        await refreshTask?.value

        XCTAssertEqual(cache.payload?.nodes.map(\.rawID), ["mac-mini"])
        XCTAssertEqual(cache.payload?.workspaces.map(\.title), ["prod-main"])
        XCTAssertEqual(cache.payload?.defaultTeamID, "personal:user-1")
    }

    func testUnlinkHiveNodeUsesRawNodeIDAndSelectedTeam() async {
        let authStore = MemoryHiveAuthSessionStore(
            session: CmxStackAuthSession(refreshToken: "refresh", accessToken: "access")
        )
        let control = RecordingHiveControlClient(
            teamsSnapshot: CmxHiveTeamsSnapshot(
                teams: [CmxHiveTeam(id: "team-alpha", displayName: "Alpha Team", isPersonal: false)],
                defaultTeamID: "personal:user-1",
                selectedTeamID: nil
            )
        )
        let node = CmxHiveNode(
            id: 41,
            rawID: "mac-mini-node",
            name: "Mac mini",
            subtitle: "offline",
            symbolName: "macmini",
            platform: .macOS,
            isOnline: false
        )
        let workspace = CmxWorkspace(
            id: 99,
            nodeID: 41,
            title: "main",
            preview: "old workspace",
            lastActivity: Date(timeIntervalSince1970: 1_777_680_000),
            unread: false,
            pinned: false,
            spaces: []
        )
        let store = CmxConnectionStore(
            authSessionStore: authStore,
            pairingSecretClient: RecordingHivePairingSecretClient(),
            hiveDiscoveryClient: RecordingHiveDiscoveryClient(snapshot: CmxHiveDiscoverySnapshot(nodes: [], workspaces: [])),
            hiveControlClient: control,
            hiveTeamPreferenceStore: MemoryHiveTeamPreferenceStore(selectedTeamID: "team-alpha"),
            hiveDiscoveryCacheStore: MemoryHiveDiscoveryCacheStore(),
            hiveDiscoveryEndpoint: URL(string: "https://rivet.example/hive")!,
            terminalSessionFactory: RecordingHiveTerminalSessionFactory(),
            startHiveDiscoveryOnInit: false
        )
        store.applyHiveDiscoverySnapshot(CmxHiveDiscoverySnapshot(nodes: [node], workspaces: [workspace]))

        let unlinkTask = store.unlinkHiveNode(node)
        await unlinkTask?.value

        XCTAssertEqual(control.unlinkedNodeIDs, ["mac-mini-node"])
        XCTAssertEqual(control.unlinkTeamIDs, ["team-alpha"])
        XCTAssertTrue(store.nodes.isEmpty)
        XCTAssertTrue(store.workspaces.isEmpty)
    }

    func testSelectingOnlineHiveWorkspaceWithAttachTicketStartsTerminalConnection() {
        let ticket = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": { "id": "endpoint-public-key", "addrs": [] },
          "auth": { "mode": "direct" },
          "node": {
            "id": "mac-mini-node",
            "name": "Mac mini",
            "kind": "macmini"
          }
        }
        """
        let node = CmxHiveNode(
            id: 41,
            rawID: "mac-mini-node",
            name: "Mac mini",
            subtitle: "online",
            symbolName: "macmini",
            platform: .macOS,
            isOnline: true,
            attachTicket: ticket
        )
        let workspace = CmxWorkspace(
            id: 99,
            nodeID: 41,
            title: "main",
            preview: "shared shell",
            lastActivity: Date(timeIntervalSince1970: 1_777_680_000),
            unread: false,
            pinned: false,
            spaces: [],
            localWorkspaceID: "123"
        )
        let sessionFactory = RecordingHiveTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryHiveAuthSessionStore(),
            pairingSecretClient: RecordingHivePairingSecretClient(),
            hiveDiscoveryClient: RecordingHiveDiscoveryClient(snapshot: CmxHiveDiscoverySnapshot(nodes: [], workspaces: [])),
            hiveControlClient: RecordingHiveControlClient(
                teamsSnapshot: CmxHiveTeamsSnapshot(teams: [], defaultTeamID: nil, selectedTeamID: nil)
            ),
            hiveDiscoveryCacheStore: MemoryHiveDiscoveryCacheStore(),
            terminalSessionFactory: sessionFactory,
            startHiveDiscoveryOnInit: false
        )
        store.applyHiveDiscoverySnapshot(CmxHiveDiscoverySnapshot(nodes: [node], workspaces: [workspace]))

        store.select(workspace: workspace)

        XCTAssertEqual(store.ticketText, ticket)
        XCTAssertEqual(sessionFactory.lastRawTicket, ticket)
        XCTAssertTrue(sessionFactory.session.didStart)
    }

    func testHiveAttachSelectionMatchesMacAdapterStableWorkspaceID() {
        let ticket = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": { "id": "endpoint-public-key", "addrs": [] },
          "auth": { "mode": "direct" },
          "node": {
            "id": "mac-mini-node",
            "name": "Mac mini",
            "kind": "macmini"
          }
        }
        """
        let node = CmxHiveNode(
            id: CmxStableID.uint64(for: "mac-mini-node"),
            rawID: "mac-mini-node",
            name: "Mac mini",
            subtitle: "online",
            symbolName: "macmini",
            platform: .macOS,
            isOnline: true,
            attachTicket: ticket
        )
        let localWorkspaceID = "F6D1067A-8B1B-4205-84F2-D5A1618B3A30"
        let hiveWorkspace = CmxWorkspace(
            id: CmxStableID.uint64(for: "mac-mini-node:\(localWorkspaceID)"),
            nodeID: node.id,
            title: "main",
            preview: "shared shell",
            lastActivity: Date(timeIntervalSince1970: 1_777_680_000),
            unread: false,
            pinned: false,
            spaces: [],
            localWorkspaceID: localWorkspaceID
        )
        let sessionFactory = RecordingHiveTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryHiveAuthSessionStore(),
            pairingSecretClient: RecordingHivePairingSecretClient(),
            hiveDiscoveryClient: RecordingHiveDiscoveryClient(snapshot: CmxHiveDiscoverySnapshot(nodes: [], workspaces: [])),
            hiveControlClient: RecordingHiveControlClient(
                teamsSnapshot: CmxHiveTeamsSnapshot(teams: [], defaultTeamID: nil, selectedTeamID: nil)
            ),
            hiveDiscoveryCacheStore: MemoryHiveDiscoveryCacheStore(),
            terminalSessionFactory: sessionFactory,
            startHiveDiscoveryOnInit: false
        )
        store.applyHiveDiscoverySnapshot(CmxHiveDiscoverySnapshot(nodes: [node], workspaces: [hiveWorkspace]))

        store.select(workspace: hiveWorkspace)
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .welcome(serverVersion: "cmux-macos-adapter", sessionID: "ios-session")
        )

        let otherWorkspaceID = CmxStableID.uint64(for: "mac-mini-node:other-workspace")
        let targetWorkspaceID = CmxStableID.uint64(for: "mac-mini-node:\(localWorkspaceID)")
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
                workspaces: [
                    CmxNativeWorkspaceInfo(
                        id: otherWorkspaceID,
                        title: "main",
                        spaceCount: 1,
                        tabCount: 1,
                        terminalCount: 1,
                        pinned: false,
                        color: nil
                    ),
                    CmxNativeWorkspaceInfo(
                        id: targetWorkspaceID,
                        title: "main",
                        spaceCount: 1,
                        tabCount: 1,
                        terminalCount: 1,
                        pinned: false,
                        color: nil
                    ),
                ],
                activeWorkspace: 0,
                activeWorkspaceID: otherWorkspaceID,
                spaces: [CmxNativeSpaceInfo(id: 10, title: "main", paneCount: 1, terminalCount: 1)],
                activeSpace: 0,
                activeSpaceID: 10,
                panels: .leaf(
                    panelID: 20,
                    tabs: [CmxNativeTabInfo(id: 30, title: "shell", hasActivity: false, bellCount: 0)],
                    active: 0,
                    activeTabID: 30
                ),
                focusedPanelID: 20,
                focusedTabID: 30
            ))
        )

        XCTAssertEqual(sessionFactory.session.sentCommands.last, .selectWorkspace(index: 1))
        XCTAssertEqual(store.selectedWorkspaceID, targetWorkspaceID)
    }
}

private final class CmxHiveDiscoveryURLProtocol: URLProtocol {
    private static let handlerStore = CmxURLProtocolHandlerStore()

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlerStore.handler }
        set { handlerStore.handler = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class CmxURLProtocolHandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }
}

private final class MemoryHiveAuthSessionStore: CmxStackAuthSessionStore {
    var session: CmxStackAuthSession?

    init(session: CmxStackAuthSession? = nil) {
        self.session = session
    }

    func load() throws -> CmxStackAuthSession? {
        session
    }

    func save(_ session: CmxStackAuthSession) throws {
        self.session = session
    }

    func clear() throws {
        session = nil
    }
}

private final class MemoryHiveTeamPreferenceStore: CmxHiveTeamPreferenceStoring {
    var selectedTeamID: String?

    init(selectedTeamID: String? = nil) {
        self.selectedTeamID = selectedTeamID
    }

    func loadSelectedTeamID() throws -> String? {
        selectedTeamID
    }

    func saveSelectedTeamID(_ teamID: String?) throws {
        selectedTeamID = teamID
    }
}

private final class MemoryHiveDiscoveryCacheStore: CmxHiveDiscoveryCacheStoring {
    var payload: CmxHiveDiscoveryCachePayload?

    init(payload: CmxHiveDiscoveryCachePayload? = nil) {
        self.payload = payload
    }

    func load() throws -> CmxHiveDiscoveryCachePayload? {
        payload
    }

    func save(_ payload: CmxHiveDiscoveryCachePayload) throws {
        self.payload = payload
    }

    func clear() throws {
        payload = nil
    }
}

private final class RecordingHiveDiscoveryClient: CmxHiveDiscoveryFetching {
    let snapshot: CmxHiveDiscoverySnapshot
    private(set) var fetchCount = 0
    private(set) var lastEndpoint: URL?
    private(set) var lastStackSession: CmxStackAuthSession?
    private(set) var lastTeamID: String?

    init(snapshot: CmxHiveDiscoverySnapshot) {
        self.snapshot = snapshot
    }

    func fetchHive(
        endpoint: URL,
        stackSession: CmxStackAuthSession,
        teamID: String?
    ) async throws -> CmxHiveDiscoverySnapshot {
        fetchCount += 1
        lastEndpoint = endpoint
        lastStackSession = stackSession
        lastTeamID = teamID
        return snapshot
    }
}

private final class RecordingHiveControlClient: CmxHiveControlFetching {
    let teamsSnapshot: CmxHiveTeamsSnapshot
    private(set) var fetchTeamsCount = 0
    private(set) var unlinkedNodeIDs: [String] = []
    private(set) var unlinkTeamIDs: [String?] = []

    init(teamsSnapshot: CmxHiveTeamsSnapshot) {
        self.teamsSnapshot = teamsSnapshot
    }

    func fetchTeams(
        endpoint _: URL,
        stackSession _: CmxStackAuthSession
    ) async throws -> CmxHiveTeamsSnapshot {
        fetchTeamsCount += 1
        return teamsSnapshot
    }

    func unlinkNode(
        nodeID: String,
        endpoint _: URL,
        stackSession _: CmxStackAuthSession,
        teamID: String?
    ) async throws {
        unlinkedNodeIDs.append(nodeID)
        unlinkTeamIDs.append(teamID)
    }
}

private final class RecordingHivePairingSecretClient: CmxRivetPairingSecretFetching {
    func fetchSecret(
        for auth: CmxBridgeTicketAuth,
        stackSession: CmxStackAuthSession,
        now: Date
    ) async throws -> CmxRivetPairingSecret {
        CmxRivetPairingSecret(pairingID: auth.pairingID ?? "", secret: "secret", expiresAtUnix: 4_000_000_000)
    }
}

@MainActor
private final class RecordingHiveTerminalSessionFactory: CmxTerminalSessionMaking {
    private(set) var lastRawTicket: String?
    let session = RecordingHiveTerminalSession()

    func makeSession(
        rawTicket: String,
        ticket: CmxBridgeTicket,
        pairingSecret: String?,
        stackAuthSession: CmxStackAuthSession?
    ) throws -> any CmxTerminalSession {
        lastRawTicket = rawTicket
        return session
    }
}

@MainActor
private final class RecordingHiveTerminalSession: CmxTerminalSession {
    weak var delegate: CmxTerminalSessionDelegate?
    private(set) var didStart = false
    private(set) var sentCommands: [CmxClientCommand] = []

    func start(viewport: CmxWireViewport) {
        didStart = true
    }

    func sendInput(_ data: Data, terminalID: UInt64) {}

    func sendResize(_ viewport: CmxWireViewport, terminalID: UInt64) {}

    func sendNativeLayout(_ terminals: [CmxWireTerminalViewport]) {}

    func requestPtyReplay(terminalID: UInt64) {}

    func sendCommand(_ command: CmxClientCommand) {
        sentCommands.append(command)
    }

    func disconnect() {}
}
