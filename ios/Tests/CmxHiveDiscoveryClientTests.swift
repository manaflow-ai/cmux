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
            stackSession: CmxStackAuthSession(refreshToken: "refresh", accessToken: "access")
        )

        XCTAssertEqual(snapshot.nodes.map(\.name), ["Lawrence MacBook Pro"])
        XCTAssertEqual(snapshot.nodes.first?.platform, .macOS)
        XCTAssertEqual(snapshot.nodes.first?.symbolName, "laptopcomputer")
        XCTAssertEqual(snapshot.workspaces.map(\.title), ["main"])
        XCTAssertEqual(snapshot.workspaces.first?.nodeID, snapshot.nodes.first?.id)
        XCTAssertEqual(snapshot.workspaces.first?.spaces.first?.terminals.first?.size, CmxTerminalSize(cols: 120, rows: 40))
    }

    func testFetchHiveRejectsInvalidEndpointBeforeNetworkRequest() async {
        let client = CmxHiveDiscoveryClient(urlSession: .shared)

        do {
            _ = try await client.fetchHive(
                endpoint: URL(string: "file:///tmp/hive.json")!,
                stackSession: CmxStackAuthSession(refreshToken: "refresh", accessToken: "access")
            )
            XCTFail("expected invalid endpoint")
        } catch {
            XCTAssertEqual(error as? CmxHiveDiscoveryError, .invalidEndpoint)
        }
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
            hiveDiscoveryEndpoint: URL(string: "https://rivet.example/hive")!,
            terminalSessionFactory: RecordingHiveTerminalSessionFactory(),
            startHiveDiscoveryOnInit: false
        )
        let refreshTask = store.refreshHiveDiscoveryIfPossible()
        await refreshTask?.value

        XCTAssertEqual(discovery.fetchCount, 1)
        XCTAssertEqual(discovery.lastEndpoint?.absoluteString, "https://rivet.example/hive")
        XCTAssertEqual(discovery.lastStackSession, CmxStackAuthSession(refreshToken: "refresh", accessToken: "access"))
        XCTAssertEqual(store.nodes.map(\.name), ["Mac mini"])
        XCTAssertEqual(store.workspaces.map(\.title), ["prod-main"])
        XCTAssertEqual(store.selectedWorkspaceID, 99)
        XCTAssertEqual(store.selectedSpaceID, 199)
        XCTAssertEqual(store.selectedTerminalID, 299)
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

private final class RecordingHiveDiscoveryClient: CmxHiveDiscoveryFetching {
    let snapshot: CmxHiveDiscoverySnapshot
    private(set) var fetchCount = 0
    private(set) var lastEndpoint: URL?
    private(set) var lastStackSession: CmxStackAuthSession?

    init(snapshot: CmxHiveDiscoverySnapshot) {
        self.snapshot = snapshot
    }

    func fetchHive(
        endpoint: URL,
        stackSession: CmxStackAuthSession
    ) async throws -> CmxHiveDiscoverySnapshot {
        fetchCount += 1
        lastEndpoint = endpoint
        lastStackSession = stackSession
        return snapshot
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
    func makeSession(
        rawTicket: String,
        ticket: CmxBridgeTicket,
        pairingSecret: String?,
        stackAuthSession: CmxStackAuthSession?
    ) throws -> any CmxTerminalSession {
        RecordingHiveTerminalSession()
    }
}

@MainActor
private final class RecordingHiveTerminalSession: CmxTerminalSession {
    weak var delegate: CmxTerminalSessionDelegate?

    func start(viewport: CmxWireViewport) {}

    func sendInput(_ data: Data, terminalID: UInt64) {}

    func sendResize(_ viewport: CmxWireViewport, terminalID: UInt64) {}

    func sendNativeLayout(_ terminals: [CmxWireTerminalViewport]) {}

    func requestPtyReplay(terminalID: UInt64) {}

    func sendCommand(_ command: CmxClientCommand) {}

    func disconnect() {}
}
