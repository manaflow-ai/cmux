import CmuxiOSFeatureKit
import CmuxiOSWebCore
import CmuxLink
import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import CryptoKit
import Foundation
import Testing

@Suite("Loopback proxy over the Mac tunnel and SSH", .serialized)
struct ProxyForwardingTests {
    static let hostID = "h_mac1"
    static let userID = "u_alice"
    static let install = "in_phone1"
    static let fast = LinkConfiguration(handshakeTimeout: .seconds(2),
                                        backoff: Backoff(initial: .milliseconds(2), maximum: .milliseconds(20)),
                                        maxConnectAttempts: 100, resumeWindow: .seconds(30))

    /// A real `MobileHost` with the tunnel family on a loopback link, and the phone's client.
    static func link(ports: [TunnelPort]) async throws -> (MobileHost, MobileLinkClient) {
        let key = P256.Signing.PrivateKey()
        let store = StaticTrustStore(devices: [PairedDevice(install: install, userID: userID, keyID: "k1",
                                                            publicKey: key.publicKey.x963Representation)])
        let network = LoopbackNetwork()
        let host = MobileHost(configuration: MobileHostConfiguration(hostID: hostID, accountUserID: userID),
                              acceptor: network.acceptor, daemon: NoDaemon(),
                              authorizer: TrustStoreAuthorizer(hostID: hostID, accountUserID: userID, store: store),
                              handlers: MobileTunnels(ports: StaticTunnelPorts(ports)).registering(),
                              linkConfiguration: fast)
        await host.start()
        let carrier = network.carrier(kind: .direct, path: .direct)
        let client = MobileLinkClient(
            hostID: hostID, signer: Signer(key: key), client: HelloClient(install: install, platform: "ios", appVersion: "1.0"),
            makeSession: {
                LinkSession(peer: LinkPeer(hostID: hostID),
                            selector: PathSelector(carriers: [carrier],
                                                   policy: PathPolicy(preferenceWindow: .milliseconds(5), upgradeRetry: nil)),
                            configuration: fast)
            })
        _ = try await client.helloOK()
        return (host, client)
    }

    @Test func aPageRequestReachesTheMacDevServerWithHostRewrittenAndTokenStripped() async throws {
        let server = try await HTTPTestServer.start()
        defer { server.stop() }
        let (host, client) = try await Self.link(ports: [TunnelPort(port: server.port, source: .detected)])
        let route = WebRoute(id: .mac(HostID("h_mac1")), dialer: LinkTunnelDialer(client: client))
        defer { Task { await route.stop(); await client.close(); await host.stop() } }
        // The dev server runs in this process, so the mirror port is taken: the proxy falls back and rewrites Host.
        let url = try await route.url(remotePort: server.port, path: "/hello")
        let local = try #require(url.port.flatMap { UInt16(exactly: $0) })
        #expect(local != server.port)
        #expect(await route.remotePort(forLocalPort: local) == server.port)
        let response = try await within {
            try await rawExchange(port: local, "GET /hello HTTP/1.1\r\nHost: localhost:\(local)\r\n"
                                  + "Cookie: theme=dark; __cmux_tunnel=\(route.cookie.value)\r\nConnection: keep-alive\r\n\r\n")
        }
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(response.hasSuffix("ok:GET /hello HTTP/1.1"))
        let head = try #require(server.receivedHeads.first)
        #expect(head.contains("Host: localhost:\(server.port)"))
        #expect(head.contains("Cookie: theme=dark"))
        #expect(!head.contains("__cmux_tunnel"))
        #expect(head.contains("Connection: close"))
    }

    @Test func aConnectionWithoutTheTokenIsRefusedBeforeAnyDial() async throws {
        let dialer = CountingDialer()
        let proxy = LoopbackProxy(remotePort: closedPort(), token: WebTunnelCookie.random().value, dialer: dialer)
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }
        let response = try await within {
            try await rawExchange(port: port, "GET / HTTP/1.1\r\nHost: localhost:\(port)\r\nCookie: __cmux_tunnel=wrong\r\n\r\n")
        }
        #expect(response.hasPrefix("HTTP/1.1 403"))
        #expect(await dialer.dials == 0)
    }

    @Test func aFreeMirrorPortKeepsTheOriginAndARefusalIsABadGateway() async throws {
        let remote = closedPort()
        let token = WebTunnelCookie.random().value
        let proxy = LoopbackProxy(remotePort: remote, token: token, dialer: CountingDialer())
        let port = try await proxy.start()
        defer { Task { await proxy.stop() } }
        #expect(port == remote)
        #expect(await proxy.mirrors)
        let response = try await within {
            try await rawExchange(port: port, "GET / HTTP/1.1\r\nHost: localhost:\(port)\r\nCookie: __cmux_tunnel=\(token)\r\n\r\n")
        }
        #expect(response.hasPrefix("HTTP/1.1 502"))
        #expect(response.contains("tunnel.port_not_allowed"))
    }

    @Test func anUnadvertisedMacPortIsRefusedByTheMac() async throws {
        let (host, client) = try await Self.link(ports: [])
        defer { Task { await client.close(); await host.stop() } }
        await #expect(throws: TunnelDialError.refused(code: "tunnel.port_not_allowed", retryable: false)) {
            _ = try await LinkTunnelDialer(client: client).dial(port: 5173)
        }
        #expect(try await LinkWebPortSource(client: client).ports().isEmpty)
    }

    @Test func sshForwardingOpensDirectTCPIPToTheServersLoopback() async throws {
        let opener = FakeSSHOpener()
        let route = WebRoute(id: .ssh(HostID("ssh_box")), dialer: SSHTunnelDialer(opener: opener))
        defer { Task { await route.stop() } }
        let remote = closedPort()
        let url = try await route.url(remotePort: remote, path: "/")
        let local = try #require(url.port.flatMap { UInt16(exactly: $0) })
        let response = try await within {
            try await rawExchange(port: local, "GET /status HTTP/1.1\r\nHost: localhost:\(local)\r\n"
                                  + "Cookie: __cmux_tunnel=\(route.cookie.value)\r\n\r\n")
        }
        #expect(response.hasSuffix("ssh:GET /status HTTP/1.1"))
        let opened = await opener.opened
        #expect(opened.count == 1)
        #expect(opened.first?.host == "127.0.0.1")
        #expect(opened.first?.port == Int(remote))
        let request = try #require(await opener.streams.first?.request)
        #expect(!request.contains("__cmux_tunnel"))
    }
}

struct Signer: MobileDeviceSigner {
    let key: P256.Signing.PrivateKey
    let install = ProxyForwardingTests.install
    let keyID = "k1"
    func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}

/// The tunnel needs no daemon.
struct NoDaemon: MobileDaemon {
    func workspaceState() async throws -> MobileWorkspaceState { MobileWorkspaceState(host: "h_mac1", workspaces: []) }
    func workspaceChanges() async -> AsyncStream<Void> { AsyncStream { _ in } }
    func perform(_ op: MobileDaemonOp, context: MobileOpContext) async throws -> MobileDaemonOpResult {
        throw MobileDaemonError(code: "proto.unsupported", message: "not in this test")
    }
    func attachTerminal(_ request: MobileTerminalAttachRequest) async throws -> any MobileTerminalAttachment {
        throw MobileDaemonError(code: "terminal.not_found", message: "not in this test")
    }
}
