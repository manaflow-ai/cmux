import Foundation
import XCTest
@testable import cmux_ios

final class CmxBridgeTicketTests: XCTestCase {
    func testWebSocketRouteNormalizesAttachPathAndExtractsToken() throws {
        let ticket = try CmxBridgeTicketParser.parse(
            """
            {
              "version": 1,
              "alpn": "/cmux/cmx/3",
              "endpoint": {
                "id": "local",
                "addrs": [
                  { "Custom": "ws://127.0.0.1:8787?token=sekrit" }
                ]
              },
              "auth": { "mode": "direct" }
            }
            """
        )

        XCTAssertEqual(ticket.webSocketURL?.absoluteString, "ws://127.0.0.1:8787/attach?token=sekrit")
        XCTAssertEqual(ticket.webSocketToken, "sekrit")
    }

    func testNativeBridgeALPNIsAccepted() throws {
        let ticket = try CmxBridgeTicketParser.parse(
            """
            {
              "version": 1,
              "alpn": "/cmux/native/1",
              "endpoint": {
                "id": "local",
                "addrs": [
                  { "Custom": "ws://127.0.0.1:8787?token=sekrit" }
                ]
              },
              "auth": { "mode": "direct" }
            }
            """
        )

        XCTAssertEqual(ticket.alpn, "/cmux/native/1")
    }

    func testRouteLabelRedactsWebSocketToken() throws {
        let route = CmxTransportAddr.custom("ws://127.0.0.1:8787/attach?token=sekrit")

        XCTAssertEqual(route.label, "custom:ws://127.0.0.1:8787/attach?token=redacted")
    }

    func testRivetStackTicketRequiresCompleteAuthMetadata() {
        XCTAssertThrowsError(
            try CmxBridgeTicketParser.parse(
                """
                {
                  "version": 1,
                  "alpn": "/cmux/cmx/3",
                  "endpoint": { "id": "node", "addrs": [] },
                  "auth": {
                    "mode": "rivet_stack",
                    "pairing_id": "",
                    "rivet_endpoint": "https://rivet.example.test",
                    "stack_project_id": "stack-project",
                    "expires_at_unix": 4000000000
                  }
                }
                """
            )
        ) { error in
            XCTAssertEqual(error as? CmxTicketError, .missingPairingID)
        }
    }

    func testTicketDecodesNodeMetadataForHiveDiscovery() throws {
        let ticket = try CmxBridgeTicketParser.parse(
            """
            {
              "version": 1,
              "alpn": "/cmux/cmx/3",
              "endpoint": {
                "id": "endpoint-public-key",
                "addrs": [
                  { "Custom": "ws://127.0.0.1:8787?token=sekrit" }
                ]
              },
              "auth": {
                "mode": "rivet_stack",
                "pairing_id": "pairing-1",
                "rivet_endpoint": "https://rivet.example.test",
                "stack_project_id": "stack-project",
                "expires_at_unix": 4000000000
              },
              "node": {
                "id": "node-mbp",
                "name": "Lawrence MacBook Pro",
                "subtitle": "local dev node",
                "kind": "macbook"
              }
            }
            """
        )

        XCTAssertEqual(
            ticket.node,
            CmxBridgeTicketNode(
                id: "node-mbp",
                name: "Lawrence MacBook Pro",
                subtitle: "local dev node",
                kind: "macbook"
            )
        )
        let node = CmxHiveNodeFactory.connectedNode(for: ticket)
        XCTAssertEqual(node.name, "Lawrence MacBook Pro")
        XCTAssertEqual(node.subtitle, "local dev node")
        XCTAssertEqual(node.symbolName, "laptopcomputer")
        XCTAssertEqual(node.platform, .macOS)
        XCTAssertTrue(node.isOnline)
    }

    func testTicketNodePlatformDetectsLinuxAndMacModifierStyle() throws {
        let mac = try CmxBridgeTicketParser.parse(
            """
            {
              "version": 1,
              "alpn": "/cmux/cmx/3",
              "endpoint": { "id": "mac-endpoint", "addrs": [] },
              "auth": { "mode": "direct" },
              "node": {
                "id": "node-mac",
                "name": "Lawrence Mac mini",
                "kind": "darwin"
              }
            }
            """
        )
        let linux = try CmxBridgeTicketParser.parse(
            """
            {
              "version": 1,
              "alpn": "/cmux/cmx/3",
              "endpoint": { "id": "linux-endpoint", "addrs": [] },
              "auth": { "mode": "direct" },
              "node": {
                "id": "node-linux",
                "name": "Build server",
                "kind": "linux"
              }
            }
            """
        )

        XCTAssertEqual(CmxHiveNodeFactory.connectedNode(for: mac).platform, .macOS)
        XCTAssertEqual(CmxHiveNodeFactory.connectedNode(for: linux).platform, .linux)
    }

    func testTicketWithoutNodeMetadataUsesStableEndpointFallbackNode() throws {
        let ticket = try CmxBridgeTicketParser.parse(
            """
            {
              "version": 1,
              "alpn": "/cmux/cmx/3",
              "endpoint": {
                "id": "abcdefghijklmnopqrstuvwxyz",
                "addrs": []
              },
              "auth": { "mode": "direct" }
            }
            """
        )

        let first = CmxHiveNodeFactory.connectedNode(for: ticket)
        let second = CmxHiveNodeFactory.connectedNode(for: ticket)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.name, "cmx node")
        XCTAssertEqual(first.subtitle, "abcdef...uvwxyz")
        XCTAssertEqual(first.symbolName, "terminal")
    }

    func testRivetStackTicketRejectsExpiredPairing() {
        XCTAssertThrowsError(
            try CmxBridgeTicketParser.parse(
                """
                {
                  "version": 1,
                  "alpn": "/cmux/cmx/3",
                  "endpoint": { "id": "node", "addrs": [] },
                  "auth": {
                    "mode": "rivet_stack",
                    "pairing_id": "pairing-1",
                    "rivet_endpoint": "https://rivet.example.test",
                    "stack_project_id": "stack-project",
                    "expires_at_unix": 10
                  }
                }
                """,
                now: Date(timeIntervalSince1970: 20)
            )
        ) { error in
            XCTAssertEqual(error as? CmxTicketError, .expiredPairing)
        }
    }

    func testLaunchConfigurationReadsTicketArgument() {
        XCTAssertEqual(
            CmxLaunchConfiguration.ticket(arguments: ["app", "--cmux-ticket", "ticket"], environment: [:]),
            "ticket"
        )
        XCTAssertTrue(
            CmxLaunchConfiguration.shouldAutoconnect(arguments: ["app", "--cmux-autoconnect"], environment: [:])
        )
    }

    func testLaunchConfigurationRejectsMissingTicketArgumentValue() {
        XCTAssertNil(CmxLaunchConfiguration.ticket(arguments: ["app", "--cmux-ticket", "--cmux-autoconnect"], environment: [:]))
    }

    func testTicketParserMapsMalformedJsonToLocalizedTicketError() {
        XCTAssertThrowsError(try CmxBridgeTicketParser.parse("{")) { error in
            XCTAssertEqual(error as? CmxTicketError, .invalidFormat)
        }
    }

    func testLaunchConfigurationReadsJsonArrayArgument() {
        let arguments = ["app", "[\"--cmux-ticket\",\"ticket\",\"--cmux-autoconnect\"]"]

        XCTAssertEqual(CmxLaunchConfiguration.ticket(arguments: arguments, environment: [:]), "ticket")
        XCTAssertTrue(CmxLaunchConfiguration.shouldAutoconnect(arguments: arguments, environment: [:]))
    }

    func testLaunchConfigurationReadsTerminalBoundsOverlayFlag() {
        XCTAssertTrue(
            CmxLaunchConfiguration.showsTerminalBoundsOverlay(
                arguments: ["app", "--cmux-show-terminal-bounds"],
                environment: [:]
            )
        )
        XCTAssertTrue(
            CmxLaunchConfiguration.showsTerminalBoundsOverlay(
                arguments: ["app"],
                environment: ["CMUX_IOS_SHOW_TERMINAL_BOUNDS": "1"]
            )
        )
        XCTAssertFalse(
            CmxLaunchConfiguration.showsTerminalBoundsOverlay(
                arguments: ["app"],
                environment: [:]
            )
        )
    }

    @MainActor
    func testExplicitLaunchTicketPersistsForIconRelaunch() {
        let launchTicketStore = MemoryLaunchTicketStateStore()
        let ticket = Self.directTicketJSON()

        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            launchTicketStore: launchTicketStore,
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: RecordingTerminalSessionFactory(),
            startHiveDiscoveryOnInit: false,
            launchTicket: ticket,
            launchAutoconnect: true
        )

        XCTAssertEqual(store.ticketText, ticket)
        XCTAssertEqual(launchTicketStore.state, CmxLaunchTicketState(ticket: ticket, autoconnect: true))
    }

    @MainActor
    func testStoredLaunchTicketAutoconnectsOnNormalIconLaunch() async {
        let launchTicketStore = MemoryLaunchTicketStateStore()
        let ticket = Self.directTicketJSON()
        launchTicketStore.state = CmxLaunchTicketState(ticket: ticket, autoconnect: true)
        let sessionFactory = RecordingTerminalSessionFactory()
        let makeExpectation = expectation(description: "opens terminal session from saved launch ticket")
        sessionFactory.makeExpectation = makeExpectation

        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            launchTicketStore: launchTicketStore,
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory,
            startHiveDiscoveryOnInit: false,
            launchTicket: nil,
            launchAutoconnect: false
        )

        await fulfillment(of: [makeExpectation], timeout: 3.0)
        XCTAssertEqual(store.ticketText, ticket)
        XCTAssertEqual(sessionFactory.lastRawTicket, ticket)
        XCTAssertTrue(sessionFactory.session.didStart)
    }

    @MainActor
    func testManualConnectPersistsValidTicketForIconRelaunch() {
        let launchTicketStore = MemoryLaunchTicketStateStore()
        let ticket = Self.directTicketJSON()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            launchTicketStore: launchTicketStore,
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: RecordingTerminalSessionFactory(),
            startHiveDiscoveryOnInit: false,
            launchTicket: nil,
            launchAutoconnect: false
        )
        store.ticketText = ticket

        store.connect()

        XCTAssertEqual(launchTicketStore.state, CmxLaunchTicketState(ticket: ticket, autoconnect: true))
    }

    @MainActor
    func testLaunchTicketStartsWithoutDemoWorkspaces() {
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: RecordingTerminalSessionFactory(),
            startHiveDiscoveryOnInit: false,
            launchTicket: "ticket",
            launchAutoconnect: false
        )

        XCTAssertEqual(store.ticketText, "ticket")
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertFalse(store.canRenderSelectedTerminal)
        XCTAssertEqual(store.terminalDetailPresentation, .notConnected)
        XCTAssertFalse(store.visibleWorkspaces(matching: "").contains { $0.title == "agent runs" })
    }

    @MainActor
    func testEmptyNativeSnapshotDoesNotRestoreDemoWorkspaces() {
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: RecordingTerminalSessionFactory(),
            startHiveDiscoveryOnInit: false,
            launchTicket: "ticket",
            launchAutoconnect: false
        )

        store.applyNativeSnapshot(CmxNativeSnapshot(
            workspaces: [],
            activeWorkspace: 0,
            activeWorkspaceID: 0,
            spaces: [],
            activeSpace: 0,
            activeSpaceID: 0,
            panels: .leaf(panelID: 0, tabs: [], active: 0, activeTabID: 0),
            focusedPanelID: 0,
            focusedTabID: 0
        ))

        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertFalse(store.canRenderSelectedTerminal)
        XCTAssertEqual(store.terminalDetailPresentation, .notConnected)
        XCTAssertFalse(store.visibleWorkspaces(matching: "").contains { $0.title == "agent runs" })
    }

    @MainActor
    func testPlaceholderTerminalDoesNotSendNativeLayoutBeforeSnapshot() {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory,
            startHiveDiscoveryOnInit: false,
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

        store.terminalScreenDidAppear()
        store.connect()
        store.updateTerminalSize(terminalID: store.selectedTerminal.id, size: CmxTerminalSize(cols: 53, rows: 52))
        store.requestPtyReplay(terminalID: store.selectedTerminal.id)
        store.sendInput(Data("x".utf8), terminalID: store.selectedTerminal.id)

        XCTAssertFalse(store.canRenderSelectedTerminal)
        XCTAssertTrue(sessionFactory.session.sentLayouts.isEmpty)
        XCTAssertTrue(sessionFactory.session.requestedPtyReplayTerminalIDs.isEmpty)
    }

    func testStackAuthCallbackParsesNativeDeepLinkWithoutLeakingTokens() throws {
        let accessPayload = #"["refresh-cookie","access-token"]"#
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "cmux-dev://auth-callback?stack_refresh=refresh-explicit&stack_access=\(accessPayload)")!

        let session = try CmxStackAuthCallback.parse(url: url)

        XCTAssertEqual(session.refreshToken, "refresh-explicit")
        XCTAssertEqual(session.accessToken, "access-token")
        XCTAssertEqual(session.authorizationHeaders["Authorization"], "Bearer access-token")
        XCTAssertEqual(session.authorizationHeaders["X-Stack-Refresh-Token"], "refresh-explicit")
        XCTAssertFalse(String(describing: session).contains("access-token"))
        XCTAssertFalse(String(describing: session).contains("refresh-explicit"))
    }

    func testStackAuthCallbackAcceptsNightlyScheme() throws {
        let session = try CmxStackAuthCallback.parse(
            url: URL(string: "cmux-nightly://auth-callback?stack_refresh=refresh&stack_access=access")!
        )

        XCTAssertEqual(session.refreshToken, "refresh")
        XCTAssertEqual(session.accessToken, "access")
    }

    func testStackAuthCallbackRejectsMissingTokens() {
        XCTAssertThrowsError(
            try CmxStackAuthCallback.parse(url: URL(string: "cmux://auth-callback?stack_refresh=refresh")!)
        ) { error in
            XCTAssertEqual(error as? CmxStackAuthCallbackError, .missingTokens)
        }
    }

    @MainActor
    func testConnectionStorePersistsStackAuthCallbackAndCanSignOut() {
        let sessionStore = MemoryStackAuthSessionStore()
        let store = CmxConnectionStore(authSessionStore: sessionStore)

        store.handleOpenURL(URL(string: "cmux://auth-callback?stack_refresh=refresh&stack_access=access")!)

        XCTAssertEqual(store.stackAuthSession, CmxStackAuthSession(refreshToken: "refresh", accessToken: "access"))
        XCTAssertEqual(sessionStore.session, CmxStackAuthSession(refreshToken: "refresh", accessToken: "access"))

        store.signOut()

        XCTAssertNil(store.stackAuthSession)
        XCTAssertNil(sessionStore.session)
    }

    @MainActor
    func testNativeSnapshotDoesNotMarkInactiveWorkspacesUnreadFromActiveTabs() {
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: RecordingTerminalSessionFactory()
        )
        store.applyNativeSnapshot(CmxNativeSnapshot(
            workspaces: [
                CmxNativeWorkspaceInfo(id: 1, title: "main", spaceCount: 1, tabCount: 1, terminalCount: 1, pinned: false, color: nil),
                CmxNativeWorkspaceInfo(id: 2, title: "agents", spaceCount: 1, tabCount: 1, terminalCount: 1, pinned: false, color: nil),
            ],
            activeWorkspace: 0,
            activeWorkspaceID: 1,
            spaces: [CmxNativeSpaceInfo(id: 10, title: "space", paneCount: 1, terminalCount: 1)],
            activeSpace: 0,
            activeSpaceID: 10,
            panels: .leaf(
                panelID: 20,
                tabs: [CmxNativeTabInfo(id: 30, title: "shell", hasActivity: true, bellCount: 1)],
                active: 0,
                activeTabID: 30
            ),
            focusedPanelID: 20,
            focusedTabID: 30
        ))

        XCTAssertFalse(store.workspaces.first(where: { $0.id == 2 })?.unread ?? true)
    }

    @MainActor
    func testRivetStackTicketRequiresStoredStackSessionBeforeConnect() {
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: RecordingTerminalSessionFactory()
        )
        store.ticketText = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": {
            "id": "endpoint-public-key",
            "addrs": [
              { "Custom": "ws://127.0.0.1:8787?token=dev" }
            ]
          },
          "auth": {
            "mode": "rivet_stack",
            "pairing_id": "pairing-1",
            "rivet_endpoint": "https://rivet.example.test",
            "stack_project_id": "stack-project",
            "expires_at_unix": 4000000000
          }
        }
        """

        store.connect()

        XCTAssertNil(store.ticket)
        XCTAssertFalse(store.isConnecting)
        XCTAssertFalse(store.isConnected)
        XCTAssertEqual(store.errorText, CmxConnectionError.missingStackAuthSession.errorDescription)
    }

    @MainActor
    func testRivetStackTicketFetchesPairingSecretBeforeOpeningTransport() async {
        let sessionStore = MemoryStackAuthSessionStore()
        sessionStore.session = CmxStackAuthSession(refreshToken: "refresh", accessToken: "access")
        let secretClient = RecordingPairingSecretClient()
        let sessionFactory = RecordingTerminalSessionFactory()
        let fetchExpectation = expectation(description: "fetches Rivet pairing secret")
        let makeExpectation = expectation(description: "opens terminal session")
        secretClient.fetchExpectation = fetchExpectation
        sessionFactory.makeExpectation = makeExpectation
        let store = CmxConnectionStore(
            authSessionStore: sessionStore,
            pairingSecretClient: secretClient,
            terminalSessionFactory: sessionFactory
        )
        store.ticketText = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": { "id": "endpoint-public-key", "addrs": [] },
          "auth": {
            "mode": "rivet_stack",
            "pairing_id": "pairing-1",
            "rivet_endpoint": "https://rivet.example.test/cmux",
            "stack_project_id": "stack-project",
            "expires_at_unix": 4000000000
          }
        }
        """

        store.connect()
        await fulfillment(of: [fetchExpectation, makeExpectation], timeout: 3.0)

        XCTAssertEqual(secretClient.fetchCount, 1)
        XCTAssertEqual(secretClient.lastStackSession, sessionStore.session)
        XCTAssertEqual(sessionFactory.lastPairingSecret, "rivet-secret")
        XCTAssertEqual(sessionFactory.lastStackAuthSession, sessionStore.session)
        XCTAssertTrue(sessionFactory.session.didStart)
        XCTAssertNil(store.errorText)
        XCTAssertTrue(store.isConnecting)
        XCTAssertFalse(store.isConnected)
    }

    @MainActor
    func testDirectIrohTicketWithoutWebSocketStartsTerminalSession() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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

        XCTAssertNil(sessionFactory.lastPairingSecret)
        XCTAssertTrue(sessionFactory.session.didStart)
        XCTAssertNil(store.errorText)
    }

    @MainActor
    func testConnectionStoreSurfacesActiveSessionLatency() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didUpdateLatencyMilliseconds: 42
        )

        XCTAssertEqual(store.latencyMilliseconds, 42)
        XCTAssertEqual(store.latencyText, "42 ms")

        store.disconnect()

        XCTAssertNil(store.latencyMilliseconds)
        XCTAssertNil(store.latencyText)
    }

    @MainActor
    func testVisibleTerminalResizeSendsActiveSessionResize() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
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
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41
            ))
        )
        store.terminalScreenDidAppear()
        sessionFactory.session.clearRecordedResizes()
        sessionFactory.session.clearRecordedLayouts()

        store.updateTerminalSize(terminalID: 41, size: CmxTerminalSize(cols: 100, rows: 20))

        XCTAssertEqual(sessionFactory.session.sentResizes.count, 0)
        XCTAssertEqual(
            sessionFactory.session.sentLayouts.last,
            [CmxWireTerminalViewport(tabID: 41, cols: 100, rows: 20)]
        )
    }

    @MainActor
    func testPtyBytesAdvanceTerminalOutputRevisionForLiveGhosttyRepaint() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
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
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41
            ))
        )
        let revisionBeforePTY = store.terminalOutputRevision

        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .ptyBytes(tabID: 41, data: Data("live".utf8))
        )

        XCTAssertEqual(store.terminalOutputRevision, revisionBeforePTY + 1)
        XCTAssertEqual(store.outputChunks(for: 41).last?.data, Data("live".utf8))
    }

    @MainActor
    func testControlOnlyPtyBytesDoNotPresentBlankTerminalAsReady() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
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
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41
            ))
        )

        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .ptyBytes(tabID: 41, data: Data("\u{1B}[2J\u{1B}[H".utf8))
        )

        XCTAssertFalse(store.outputChunks(for: 41).isEmpty)
        XCTAssertFalse(store.selectedTerminalOutputIsReady)
        XCTAssertEqual(store.terminalDetailPresentation, .loadingTerminal)

        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .ptyBytes(tabID: 41, data: Data("shell prompt\r\n".utf8))
        )

        XCTAssertTrue(store.selectedTerminalOutputIsReady)
        XCTAssertEqual(store.terminalDetailPresentation, .terminal)
    }

    @MainActor
    func testReconnectDoesNotSeedBlankTerminalOutput() throws {
        let sessionFactory = ReconnectingRecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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
        let firstSession = try XCTUnwrap(sessionFactory.latestSession)
        firstSession.delegate?.terminalSession(
            firstSession,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
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
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41
            ))
        )
        firstSession.delegate?.terminalSession(
            firstSession,
            didReceive: .ptyBytes(tabID: 41, data: Data("cached prompt\r\n".utf8))
        )
        XCTAssertTrue(store.selectedTerminalOutputIsReady)

        store.connect()

        XCTAssertTrue(store.outputChunks(for: 41).isEmpty)
        XCTAssertFalse(store.selectedTerminalOutputIsReady)
        XCTAssertEqual(store.terminalDetailPresentation, .loadingTerminal)
    }

    @MainActor
    func testStoreCoalescesBatchedPtyBytesBeforePublishingOutput() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
                workspaces: [
                    CmxNativeWorkspaceInfo(
                        id: 11,
                        title: "main",
                        spaceCount: 1,
                        tabCount: 2,
                        terminalCount: 2,
                        pinned: false,
                        color: nil
                    ),
                ],
                activeWorkspace: 0,
                activeWorkspaceID: 11,
                spaces: [
                    CmxNativeSpaceInfo(id: 21, title: "space-1", paneCount: 1, terminalCount: 2),
                ],
                activeSpace: 0,
                activeSpaceID: 21,
                panels: .leaf(
                    panelID: 31,
                    tabs: [
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                        CmxNativeTabInfo(id: 42, title: "logs", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41
            ))
        )
        let revisionBeforePTY = store.terminalOutputRevision

        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: [
                .ptyBytes(tabID: 41, data: Data("one".utf8)),
                .ptyBytes(tabID: 41, data: Data("two".utf8)),
                .ptyBytes(tabID: 42, data: Data("logs".utf8)),
                .ptyBytes(tabID: 41, data: Data("three".utf8)),
            ]
        )

        XCTAssertEqual(store.terminalOutputRevision, revisionBeforePTY + 3)
        XCTAssertEqual(store.outputChunks(for: 41).suffix(2).map(\.data), [
            Data("onetwo".utf8),
            Data("three".utf8),
        ])
        XCTAssertEqual(store.outputChunks(for: 42).last?.data, Data("logs".utf8))
    }

    @MainActor
    func testStoreRequestsPtyReplayForSelectedTerminal() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
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
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41
            ))
        )

        store.requestPtyReplay(terminalID: 41)
        store.requestPtyReplay(terminalID: 999)

        XCTAssertEqual(sessionFactory.session.requestedPtyReplayTerminalIDs, [41])
    }

    @MainActor
    func testRepeatedNativeSnapshotDoesNotForceVisibleTerminalReplay() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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
        let firstSnapshot = CmxNativeSnapshot(
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
                    CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                ],
                active: 0,
                activeTabID: 41
            ),
            focusedPanelID: 31,
            focusedTabID: 41
        )
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(firstSnapshot)
        )
        store.terminalScreenDidAppear()
        XCTAssertEqual(sessionFactory.session.requestedPtyReplayTerminalIDs, [41])
        XCTAssertFalse(store.selectedTerminalOutputIsReady)
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .ptyBytes(tabID: 41, data: Data("main workspace output\r\n".utf8))
        )
        XCTAssertFalse(store.outputChunks(for: 41).isEmpty)
        XCTAssertTrue(store.selectedTerminalOutputIsReady)

        sessionFactory.session.clearRecordedLayouts()
        sessionFactory.session.clearRequestedPtyReplays()
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(firstSnapshot)
        )

        XCTAssertTrue(sessionFactory.session.sentLayouts.isEmpty)
        XCTAssertTrue(sessionFactory.session.requestedPtyReplayTerminalIDs.isEmpty)

        let secondSnapshot = CmxNativeSnapshot(
            workspaces: [
                CmxNativeWorkspaceInfo(
                    id: 11,
                    title: "main",
                    spaceCount: 1,
                    tabCount: 2,
                    terminalCount: 2,
                    pinned: false,
                    color: nil
                ),
            ],
            activeWorkspace: 0,
            activeWorkspaceID: 11,
            spaces: [
                CmxNativeSpaceInfo(id: 21, title: "space-1", paneCount: 1, terminalCount: 2),
            ],
            activeSpace: 0,
            activeSpaceID: 21,
            panels: .leaf(
                panelID: 31,
                tabs: [
                    CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    CmxNativeTabInfo(id: 42, title: "logs", hasActivity: false, bellCount: 0),
                ],
                active: 1,
                activeTabID: 42
            ),
            focusedPanelID: 31,
            focusedTabID: 42
        )
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(secondSnapshot)
        )

        XCTAssertEqual(sessionFactory.session.sentLayouts.last, [
            CmxWireTerminalViewport(tabID: 42, cols: 80, rows: 24),
        ])
        XCTAssertEqual(sessionFactory.session.requestedPtyReplayTerminalIDs, [42])
    }

    @MainActor
    func testActiveWorkspaceChangeRequestsReplayEvenWhenFocusedTerminalIDIsUnchanged() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
        )
        store.ticketText = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": { "id": "endpoint-public-key", "addrs": [] },
          "auth": { "mode": "direct" }
        }
        """

        func snapshot(activeWorkspaceID: UInt64, title: String) -> CmxNativeSnapshot {
            CmxNativeSnapshot(
                workspaces: [
                    CmxNativeWorkspaceInfo(
                        id: activeWorkspaceID,
                        title: title,
                        spaceCount: 1,
                        tabCount: 1,
                        terminalCount: 1,
                        pinned: false,
                        color: nil
                    ),
                ],
                activeWorkspace: 0,
                activeWorkspaceID: activeWorkspaceID,
                spaces: [
                    CmxNativeSpaceInfo(id: activeWorkspaceID + 10, title: "space-1", paneCount: 1, terminalCount: 1),
                ],
                activeSpace: 0,
                activeSpaceID: activeWorkspaceID + 10,
                panels: .leaf(
                    panelID: activeWorkspaceID + 20,
                    tabs: [
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: activeWorkspaceID + 20,
                focusedTabID: 41
            )
        }

        store.connect()
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(snapshot(activeWorkspaceID: 11, title: "main"))
        )
        store.terminalScreenDidAppear()
        XCTAssertEqual(sessionFactory.session.requestedPtyReplayTerminalIDs, [41])

        sessionFactory.session.clearRecordedLayouts()
        sessionFactory.session.clearRequestedPtyReplays()
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(snapshot(activeWorkspaceID: 12, title: "cycle-1"))
        )

        XCTAssertEqual(sessionFactory.session.sentLayouts.last, [
            CmxWireTerminalViewport(tabID: 41, cols: 80, rows: 24),
        ])
        XCTAssertEqual(sessionFactory.session.requestedPtyReplayTerminalIDs, [41])
        XCTAssertTrue(store.outputChunks(for: 41).isEmpty)
        XCTAssertFalse(store.selectedTerminalOutputIsReady)
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .ptyBytes(tabID: 41, data: Data("cycle workspace output\r\n".utf8))
        )
        XCTAssertTrue(store.selectedTerminalOutputIsReady)
    }

    @MainActor
    func testVisibleTerminalResizeRequestsFreshReplayEvenWithCachedOutput() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
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
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41
            ))
        )
        store.terminalScreenDidAppear()
        sessionFactory.session.clearRequestedPtyReplays()
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .ptyBytes(tabID: 41, data: Data("cached output\r\n".utf8))
        )

        store.updateTerminalSize(terminalID: 41, size: CmxTerminalSize(cols: 54, rows: 52))

        XCTAssertEqual(
            sessionFactory.session.sentLayouts.last,
            [CmxWireTerminalViewport(tabID: 41, cols: 54, rows: 52)]
        )
        XCTAssertEqual(sessionFactory.session.requestedPtyReplayTerminalIDs, [41])
    }

    @MainActor
    func testRepeatedReconnectsCycleFiveWorkspacesWithFreshReplayAndCurrentLayout() throws {
        let sessionFactory = ReconnectingRecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
        )
        store.ticketText = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": { "id": "endpoint-public-key", "addrs": [] },
          "auth": { "mode": "direct" }
        }
        """
        let workspaceIDs = (0..<5).map { UInt64(110 + $0) }
        let spaceIDs = (0..<5).map { UInt64(210 + $0) }
        let panelIDs = (0..<5).map { UInt64(310 + $0) }
        let tabIDs = (0..<5).map { UInt64(410 + $0) }

        func localSize(pass: Int, index: Int) -> CmxTerminalSize {
            CmxTerminalSize(cols: 104 - index * 5 - pass, rows: 42 - index * 2 - pass)
        }

        func remoteSize(pass: Int, index: Int) -> CmxTerminalSize {
            CmxTerminalSize(cols: 74 - index * 3 - pass, rows: 28 - index - pass)
        }

        func snapshot(active index: Int, pass: Int) -> CmxNativeSnapshot {
            let remote = remoteSize(pass: pass, index: index)
            return CmxNativeSnapshot(
                workspaces: workspaceIDs.enumerated().map { offset, workspaceID in
                    CmxNativeWorkspaceInfo(
                        id: workspaceID,
                        title: "cycle-\(offset)",
                        spaceCount: 1,
                        tabCount: 1,
                        terminalCount: 1,
                        pinned: false,
                        color: nil
                    )
                },
                activeWorkspace: index,
                activeWorkspaceID: workspaceIDs[index],
                spaces: [
                    CmxNativeSpaceInfo(
                        id: spaceIDs[index],
                        title: "space-\(index)",
                        paneCount: 1,
                        terminalCount: 1
                    ),
                ],
                activeSpace: 0,
                activeSpaceID: spaceIDs[index],
                panels: .leaf(
                    panelID: panelIDs[index],
                    tabs: [
                        CmxNativeTabInfo(
                            id: tabIDs[index],
                            title: "shell-\(index)",
                            hasActivity: false,
                            bellCount: 0
                        ),
                    ],
                    active: 0,
                    activeTabID: tabIDs[index]
                ),
                focusedPanelID: panelIDs[index],
                focusedTabID: tabIDs[index],
                attachedClients: [
                    CmxAttachedClientInfo(
                        clientID: "cmuxtmux",
                        kind: .tui,
                        visibleTerminalCount: 1,
                        updatedAtMilliseconds: UInt64(1_000 + pass * 10 + index),
                        terminals: [
                            CmxWireTerminalViewport(
                                tabID: tabIDs[index],
                                cols: UInt16(remote.cols),
                                rows: UInt16(remote.rows)
                            ),
                        ],
                        latencyMilliseconds: 3
                    ),
                ]
            )
        }

        store.connect()
        let firstSession = try XCTUnwrap(sessionFactory.latestSession)
        firstSession.delegate?.terminalSession(
            firstSession,
            didReceive: .welcome(serverVersion: "test", sessionID: "ios-initial")
        )
        firstSession.delegate?.terminalSession(
            firstSession,
            didReceive: .nativeSnapshot(snapshot(active: 0, pass: 0))
        )
        store.terminalScreenDidAppear()

        for pass in 0..<2 {
            for index in 0..<workspaceIDs.count {
                let workspace = try XCTUnwrap(
                    store.workspaces.first(where: { $0.id == workspaceIDs[index] })
                )
                let activeBeforeReconnect = try XCTUnwrap(sessionFactory.latestSession)
                activeBeforeReconnect.clearSentCommands()
                store.select(workspace: workspace)
                XCTAssertEqual(activeBeforeReconnect.sentCommands.last, .selectWorkspace(index: index))

                store.disconnect()
                store.connect()

                let session = try XCTUnwrap(sessionFactory.latestSession)
                XCTAssertFalse(session === activeBeforeReconnect)
                session.delegate?.terminalSession(
                    session,
                    didReceive: .welcome(serverVersion: "test", sessionID: "ios-\(pass)-\(index)")
                )
                session.delegate?.terminalSession(
                    session,
                    didReceive: .nativeSnapshot(snapshot(active: index, pass: pass))
                )

                let tabID = tabIDs[index]
                let local = localSize(pass: pass, index: index)
                let remote = remoteSize(pass: pass, index: index)
                store.updateTerminalSize(terminalID: tabID, size: local)

                XCTAssertEqual(store.selectedWorkspaceID, workspaceIDs[index])
                XCTAssertEqual(store.selectedSpaceID, spaceIDs[index])
                XCTAssertEqual(store.selectedTerminalID, tabID)
                XCTAssertEqual(store.terminalSize(for: tabID), local)
                XCTAssertEqual(store.renderSize(for: tabID), remote)
                XCTAssertEqual(
                    session.sentLayouts.last,
                    [
                        CmxWireTerminalViewport(
                            tabID: tabID,
                            cols: UInt16(local.cols),
                            rows: UInt16(local.rows)
                        ),
                    ]
                )
                XCTAssertTrue(
                    session.requestedPtyReplayTerminalIDs.contains(tabID),
                    "reconnect pass \(pass) workspace \(index) should request a fresh replay"
                )

                let marker = Data("fresh workspace \(index) pass \(pass)\r\n".utf8)
                session.delegate?.terminalSession(
                    session,
                    didReceive: .ptyBytes(tabID: tabID, data: marker)
                )
                XCTAssertEqual(store.outputChunks(for: tabID).last?.data, marker)
            }
        }

        XCTAssertEqual(sessionFactory.sessions.count, 11)
    }

    @MainActor
    func testNativeSnapshotUsesSmallestAttachedClientSizeOnlyForRendering() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
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
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41
            ))
        )
        store.terminalScreenDidAppear()
        store.updateTerminalSize(terminalID: 41, size: CmxTerminalSize(cols: 53, rows: 52))

        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
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
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41,
                attachedClients: [
                    CmxAttachedClientInfo(
                        clientID: "ipad",
                        kind: .native,
                        visibleTerminalCount: 1,
                        updatedAtMilliseconds: 1,
                        terminals: [CmxWireTerminalViewport(tabID: 41, cols: 53, rows: 52)],
                        latencyMilliseconds: 2
                    ),
                    CmxAttachedClientInfo(
                        clientID: "iphone",
                        kind: .native,
                        visibleTerminalCount: 1,
                        updatedAtMilliseconds: 1,
                        terminals: [CmxWireTerminalViewport(tabID: 41, cols: 30, rows: 30)],
                        latencyMilliseconds: 2
                    ),
                ]
            ))
        )

        XCTAssertEqual(store.terminalSize(for: 41), CmxTerminalSize(cols: 53, rows: 52))
        XCTAssertEqual(store.renderSize(for: 41), CmxTerminalSize(cols: 30, rows: 30))
        XCTAssertEqual(
            sessionFactory.session.sentLayouts.last,
            [CmxWireTerminalViewport(tabID: 41, cols: 53, rows: 52)]
        )
    }

    @MainActor
    func testNativeSnapshotIgnoresCurrentSessionWhenComputingRenderClamp() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .welcome(serverVersion: "test", sessionID: "ipad")
        )
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
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
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41,
                attachedClients: [
                    CmxAttachedClientInfo(
                        clientID: "ipad",
                        kind: .native,
                        visibleTerminalCount: 1,
                        updatedAtMilliseconds: 1,
                        terminals: [CmxWireTerminalViewport(tabID: 41, cols: 29, rows: 25)],
                        latencyMilliseconds: 2
                    ),
                ]
            ))
        )
        store.terminalScreenDidAppear()
        store.updateTerminalSize(terminalID: 41, size: CmxTerminalSize(cols: 53, rows: 52))

        XCTAssertEqual(store.terminalSize(for: 41), CmxTerminalSize(cols: 53, rows: 52))
        XCTAssertNil(store.renderSize(for: 41))
        XCTAssertEqual(
            sessionFactory.session.sentLayouts.last,
            [CmxWireTerminalViewport(tabID: 41, cols: 53, rows: 52)]
        )
    }

    @MainActor
    func testRenderClampDoesNotExceedCurrentDeviceViewport() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .welcome(serverVersion: "test", sessionID: "iphone")
        )
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
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
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41,
                attachedClients: [
                    CmxAttachedClientInfo(
                        clientID: "ipad",
                        kind: .native,
                        visibleTerminalCount: 1,
                        updatedAtMilliseconds: 1,
                        terminals: [CmxWireTerminalViewport(tabID: 41, cols: 53, rows: 52)],
                        latencyMilliseconds: 2
                    ),
                ]
            ))
        )
        store.terminalScreenDidAppear()
        store.updateTerminalSize(terminalID: 41, size: CmxTerminalSize(cols: 29, rows: 25))

        XCTAssertEqual(store.terminalSize(for: 41), CmxTerminalSize(cols: 29, rows: 25))
        XCTAssertNil(store.renderSize(for: 41))
        XCTAssertEqual(
            sessionFactory.session.sentLayouts.last,
            [CmxWireTerminalViewport(tabID: 41, cols: 29, rows: 25)]
        )
    }

    @MainActor
    func testNativeSnapshotRequestsReplayWhenRenderClampChanges() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
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
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41,
                attachedClients: [
                    CmxAttachedClientInfo(
                        clientID: "iphone",
                        kind: .native,
                        visibleTerminalCount: 1,
                        updatedAtMilliseconds: 1,
                        terminals: [CmxWireTerminalViewport(tabID: 41, cols: 29, rows: 25)],
                        latencyMilliseconds: 2
                    ),
                ]
            ))
        )
        store.terminalScreenDidAppear()
        sessionFactory.session.clearRequestedPtyReplays()

        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
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
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41
            ))
        )

        XCTAssertEqual(store.renderSize(for: 41), nil)
        XCTAssertEqual(sessionFactory.session.requestedPtyReplayTerminalIDs, [41])
    }

    @MainActor
    func testTerminalScreenVisibilityControlsNativeLayoutAttachment() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
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
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .nativeSnapshot(CmxNativeSnapshot(
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
                        CmxNativeTabInfo(id: 41, title: "shell", hasActivity: false, bellCount: 0),
                    ],
                    active: 0,
                    activeTabID: 41
                ),
                focusedPanelID: 31,
                focusedTabID: 41
            ))
        )
        XCTAssertTrue(sessionFactory.session.sentLayouts.isEmpty)

        store.terminalScreenDidAppear()

        XCTAssertEqual(sessionFactory.session.sentLayouts.last, [
            CmxWireTerminalViewport(tabID: 41, cols: 80, rows: 24),
        ])

        sessionFactory.session.clearRecordedLayouts()
        store.terminalScreenDidDisappear()

        XCTAssertEqual(sessionFactory.session.sentLayouts, [[]])

        sessionFactory.session.clearRecordedLayouts()
        store.select(terminal: store.selectedTerminal)

        XCTAssertTrue(sessionFactory.session.sentLayouts.isEmpty)
    }

    @MainActor
    func testDefaultSessionFactoryUsesIrohWhenTicketHasNoWebSocketRoute() throws {
        let rawTicket = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": { "id": "endpoint-public-key", "addrs": [] },
          "auth": { "mode": "direct" }
        }
        """
        let ticket = try CmxBridgeTicketParser.parse(rawTicket)

        let session = try CmxDefaultTerminalSessionFactory().makeSession(
            rawTicket: rawTicket,
            ticket: ticket,
            pairingSecret: nil,
            stackAuthSession: nil
        )

        XCTAssertTrue(session is CmxIrohTerminalSession)
    }

    @MainActor
    func testDefaultSessionFactoryKeepsWebSocketForExplicitDevRoute() throws {
        let rawTicket = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": {
            "id": "local",
            "addrs": [
              { "Custom": "ws://127.0.0.1:8787?token=sekrit" }
            ]
          },
          "auth": { "mode": "direct" }
        }
        """
        let ticket = try CmxBridgeTicketParser.parse(rawTicket)

        let session = try CmxDefaultTerminalSessionFactory().makeSession(
            rawTicket: rawTicket,
            ticket: ticket,
            pairingSecret: nil,
            stackAuthSession: nil
        )

        XCTAssertTrue(session is CmxWebSocketTerminalSession)
    }

    @MainActor
    func testTransportCloseReconnectsActiveTicketOnceImmediately() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
        )
        store.ticketText = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": {
            "id": "local",
            "addrs": [
              { "Custom": "ws://127.0.0.1:8787?token=sekrit" }
            ]
          },
          "auth": { "mode": "direct" }
        }
        """

        store.connect()
        XCTAssertEqual(sessionFactory.session.startCount, 1)

        sessionFactory.session.delegate?.terminalSessionDidClose(sessionFactory.session)

        XCTAssertEqual(sessionFactory.session.startCount, 2)
        XCTAssertTrue(store.isConnecting)
        XCTAssertFalse(store.isConnected)

        sessionFactory.session.delegate?.terminalSessionDidClose(sessionFactory.session)

        XCTAssertEqual(sessionFactory.session.startCount, 2)
        XCTAssertFalse(store.isConnecting)
        XCTAssertFalse(store.isConnected)
    }

    @MainActor
    func testReplacingSessionIgnoresPreviousSessionCloseCallback() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        sessionFactory.session.notifiesCloseOnDisconnect = true
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
        )
        store.ticketText = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": { "id": "local", "addrs": [] },
          "auth": { "mode": "direct" }
        }
        """

        store.connect()
        store.connect()

        XCTAssertEqual(sessionFactory.session.startCount, 2)
        XCTAssertTrue(store.isConnecting)
        XCTAssertFalse(store.isConnected)
    }

    @MainActor
    func testLifecycleSignalReconnectsActiveTicket() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
        )
        store.ticketText = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": {
            "id": "local",
            "addrs": [
              { "Custom": "ws://127.0.0.1:8787?token=sekrit" }
            ]
          },
          "auth": { "mode": "direct" }
        }
        """

        store.connect()
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .welcome(serverVersion: "test", sessionID: "session")
        )

        store.refreshConnectionForLifecycleSignal()

        XCTAssertEqual(sessionFactory.session.startCount, 2)
        XCTAssertTrue(store.isConnecting)
        XCTAssertFalse(store.isConnected)
    }

    func testHeartbeatStateTimesOutUnansweredPing() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var heartbeat = CmxHeartbeatState(timeout: 10)

        XCTAssertEqual(heartbeat.tick(now: startedAt), .sendPing)
        XCTAssertEqual(heartbeat.tick(now: startedAt.addingTimeInterval(9)), .waitForPong)

        guard case .timedOut(let elapsed) = heartbeat.tick(now: startedAt.addingTimeInterval(10.5)) else {
            XCTFail("expected pending heartbeat to time out")
            return
        }
        XCTAssertEqual(elapsed, 10.5, accuracy: 0.001)

        heartbeat.reset()
        XCTAssertEqual(heartbeat.tick(now: startedAt.addingTimeInterval(11)), .sendPing)
    }

    func testHeartbeatStateReportsRoundedLatencyAndClearsPendingPing() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var heartbeat = CmxHeartbeatState(timeout: 10)

        XCTAssertEqual(heartbeat.tick(now: startedAt), .sendPing)
        XCTAssertEqual(heartbeat.recordPong(now: startedAt.addingTimeInterval(0.0424)), UInt32(42))
        XCTAssertNil(heartbeat.recordPong(now: startedAt.addingTimeInterval(0.050)))
    }

    @MainActor
    func testTransportFailureReconnectsActiveTicketOncePerLoss() throws {
        let sessionFactory = RecordingTerminalSessionFactory()
        let store = CmxConnectionStore(
            authSessionStore: MemoryStackAuthSessionStore(),
            pairingSecretClient: RecordingPairingSecretClient(),
            terminalSessionFactory: sessionFactory
        )
        store.ticketText = """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": {
            "id": "local",
            "addrs": [
              { "Custom": "ws://127.0.0.1:8787?token=sekrit" }
            ]
          },
          "auth": { "mode": "direct" }
        }
        """

        store.connect()
        sessionFactory.session.delegate?.terminalSession(
            sessionFactory.session,
            didReceive: .welcome(serverVersion: "test", sessionID: "session")
        )

        sessionFactory.session.delegate?.terminalSession(sessionFactory.session, didFail: CmxTestError.transportLost)

        XCTAssertEqual(sessionFactory.session.startCount, 2)
        XCTAssertTrue(store.isConnecting)
        XCTAssertFalse(store.isConnected)

        sessionFactory.session.delegate?.terminalSession(sessionFactory.session, didFail: CmxTestError.transportLost)

        XCTAssertEqual(sessionFactory.session.startCount, 2)
    }

    private static func directTicketJSON() -> String {
        """
        {
          "version": 1,
          "alpn": "/cmux/cmx/3",
          "endpoint": { "id": "endpoint-public-key", "addrs": [] },
          "auth": { "mode": "direct" }
        }
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum CmxTestError: Error {
    case transportLost
}

private final class MemoryStackAuthSessionStore: CmxStackAuthSessionStore {
    var session: CmxStackAuthSession?

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

private final class MemoryLaunchTicketStateStore: CmxLaunchTicketStateStore {
    var state: CmxLaunchTicketState?

    func load() throws -> CmxLaunchTicketState? {
        state
    }

    func save(_ state: CmxLaunchTicketState) throws {
        self.state = state
    }

    func clear() throws {
        state = nil
    }
}

private final class RecordingPairingSecretClient: CmxRivetPairingSecretFetching {
    var fetchExpectation: XCTestExpectation?
    private(set) var fetchCount = 0
    private(set) var lastStackSession: CmxStackAuthSession?

    func fetchSecret(
        for auth: CmxBridgeTicketAuth,
        stackSession: CmxStackAuthSession,
        now: Date
    ) async throws -> CmxRivetPairingSecret {
        fetchCount += 1
        lastStackSession = stackSession
        fetchExpectation?.fulfill()
        fetchExpectation = nil
        return CmxRivetPairingSecret(pairingID: auth.pairingID ?? "", secret: "rivet-secret", expiresAtUnix: 4000000000)
    }
}

@MainActor
private final class RecordingTerminalSessionFactory: CmxTerminalSessionMaking {
    let session = RecordingTerminalSession()
    var makeExpectation: XCTestExpectation?
    private(set) var lastRawTicket: String?
    private(set) var lastTicket: CmxBridgeTicket?
    private(set) var lastPairingSecret: String?
    private(set) var lastStackAuthSession: CmxStackAuthSession?

    func makeSession(
        rawTicket: String,
        ticket: CmxBridgeTicket,
        pairingSecret: String?,
        stackAuthSession: CmxStackAuthSession?
    ) throws -> any CmxTerminalSession {
        lastRawTicket = rawTicket
        lastTicket = ticket
        lastPairingSecret = pairingSecret
        lastStackAuthSession = stackAuthSession
        makeExpectation?.fulfill()
        makeExpectation = nil
        return session
    }
}

@MainActor
private final class ReconnectingRecordingTerminalSessionFactory: CmxTerminalSessionMaking {
    private(set) var sessions: [RecordingTerminalSession] = []

    var latestSession: RecordingTerminalSession? {
        sessions.last
    }

    func makeSession(
        rawTicket _: String,
        ticket _: CmxBridgeTicket,
        pairingSecret _: String?,
        stackAuthSession _: CmxStackAuthSession?
    ) throws -> any CmxTerminalSession {
        let session = RecordingTerminalSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class RecordingTerminalSession: CmxTerminalSession {
    weak var delegate: CmxTerminalSessionDelegate?
    private(set) var didStart = false
    private(set) var startCount = 0
    private(set) var sentLayouts: [[CmxWireTerminalViewport]] = []
    private(set) var sentResizes: [(viewport: CmxWireViewport, terminalID: UInt64)] = []
    private(set) var sentCommands: [CmxClientCommand] = []
    private(set) var requestedPtyReplayTerminalIDs: [UInt64] = []
    var notifiesCloseOnDisconnect = false

    func start(viewport: CmxWireViewport) {
        didStart = true
        startCount += 1
    }

    func sendInput(_ data: Data, terminalID: UInt64) {}

    func sendResize(_ viewport: CmxWireViewport, terminalID: UInt64) {
        sentResizes.append((viewport: viewport, terminalID: terminalID))
    }

    func sendNativeLayout(_ terminals: [CmxWireTerminalViewport]) {
        sentLayouts.append(terminals)
    }

    func requestPtyReplay(terminalID: UInt64) {
        requestedPtyReplayTerminalIDs.append(terminalID)
    }

    func sendCommand(_ command: CmxClientCommand) {
        sentCommands.append(command)
    }

    func disconnect() {
        if notifiesCloseOnDisconnect {
            delegate?.terminalSessionDidClose(self)
        }
    }

    func clearRecordedResizes() {
        sentResizes = []
    }

    func clearRecordedLayouts() {
        sentLayouts = []
    }

    func clearRequestedPtyReplays() {
        requestedPtyReplayTerminalIDs = []
    }

    func clearSentCommands() {
        sentCommands = []
    }
}
