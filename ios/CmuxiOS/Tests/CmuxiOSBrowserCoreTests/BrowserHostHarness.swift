import CmuxBrowserStream
import CmuxiOSBrowserCore
import CmuxiOSFeatureKit
import CmuxLink
import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import CryptoKit
import Foundation

struct TimeoutError: Error {}

/// A real `MobileHost` with the C2 browser handler on a loopback network,
/// and a phone session that passed `hello` with a paired key.
struct BrowserHostHarness {
    static let hostID = "h_mac1"
    static let userID = "u_alice"
    static let install = "in_phone1"
    static let fast = LinkConfiguration(handshakeTimeout: .seconds(2),
                                        backoff: Backoff(initial: .milliseconds(2), maximum: .milliseconds(20)),
                                        maxConnectAttempts: 100, resumeWindow: .seconds(30))

    let host: MobileHost
    let client: MobileLinkClient
    let pages: StubPages

    static func make() async throws -> BrowserHostHarness {
        let key = P256.Signing.PrivateKey()
        let store = StaticTrustStore(devices: [PairedDevice(install: install, userID: userID, keyID: "k1",
                                                            publicKey: key.publicKey.x963Representation)])
        let network = LoopbackNetwork()
        let pages = StubPages()
        let host = MobileHost(configuration: MobileHostConfiguration(hostID: hostID, accountUserID: userID),
                              acceptor: network.acceptor, daemon: EmptyDaemon(),
                              authorizer: TrustStoreAuthorizer(hostID: hostID, accountUserID: userID, store: store),
                              handlers: MobileChannelHandlers(channels: [.browser: BrowserChannelHandler(pages: pages)]),
                              linkConfiguration: fast)
        await host.start()
        let carrier = network.carrier(kind: .direct, path: .direct)
        let client = MobileLinkClient(
            hostID: hostID, signer: KeySigner(key: key), client: HelloClient(install: install, platform: "ios", appVersion: "1.0"),
            makeSession: {
                LinkSession(peer: LinkPeer(hostID: hostID),
                            selector: PathSelector(carriers: [carrier],
                                                   policy: PathPolicy(preferenceWindow: .milliseconds(5), upgradeRetry: nil)),
                            configuration: fast)
            })
        _ = try await client.helloOK()
        return BrowserHostHarness(host: host, client: client, pages: pages)
    }

    func shutdown() async {
        await client.close()
        await host.stop()
    }

    var source: LinkBrowserStreamSource {
        LinkBrowserStreamSource(clients: StubClients(client: client), directory: StubDirectory(),
                                viewport: { BrowserViewport(width: 393, height: 852, scale: 3) })
    }

    static func within<T: Sendable>(_ limit: Duration = .seconds(5), _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

struct KeySigner: MobileDeviceSigner {
    let key: P256.Signing.PrivateKey
    let install = BrowserHostHarness.install
    let keyID = "k1"

    func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}

struct StubClients: MobileLinkClientProvider {
    let client: MobileLinkClient

    func client(for host: HostID) async throws -> MobileLinkClient { client }
}

struct StubDirectory: BrowserTabDirectory {
    func tabs(on hostID: HostID) async -> AsyncStream<SourceSnapshot<[BrowserTabInfo]>> {
        AsyncStream { continuation in
            continuation.yield(SourceSnapshot(revision: 1, value: [BrowserTabInfo(id: "tab_b1", workspaceID: nil, title: "Docs",
                                                                                   url: URL(string: "https://example.com"))],
                                              connection: .live(path: "direct")))
        }
    }
}

/// One browser tab whose video source emits a keyframe and then whatever
/// the test pushes.
final class StubPages: BrowserPageHost {
    let attachment = StubAttachment()

    func attach(_ request: BrowserAttachRequest) async throws -> any BrowserPageAttachment {
        guard request.tab == "tab_b1" else { throw BrowserPageError.tabNotFound }
        return attachment
    }
}

actor StubAttachment: BrowserPageAttachment {
    nonisolated let source = StubVideo()
    nonisolated var video: any BrowserVideoSource { source }
    var geometry: BrowserPageGeometry { BrowserPageGeometry(cssWidth: 1440, cssHeight: 900, backingScale: 2) }
    private(set) var inputs: [RbInputEvent] = []
    private(set) var loads: [URL] = []

    func events() -> AsyncStream<BrowserPageEvent> {
        AsyncStream { continuation in
            continuation.yield(.page(RbPage(url: "https://example.com/", title: "Example", canGoBack: true)))
            continuation.yield(.textInput(inputType: "text", caret: nil))
        }
    }

    func apply(_ input: RbInputEvent) { inputs.append(input) }
    func load(_ url: URL) { loads.append(url) }
    func history(_ op: RbHistoryOp) {}
    func pasteboard(_ items: [RbClipboardItem]) {}
    func setVisible(_ visible: Bool) {}
    func detach() {}
}

actor StubVideo: BrowserVideoSource {
    private var keyframe = false
    private var waiter: CheckedContinuation<Void, Never>?

    func nextFrame(_ request: BrowserFrameRequest) async throws -> BrowserEncodedFrame? {
        while !keyframe {
            try Task.checkCancellation()
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter = $0 }
            } onCancel: {
                Task { await self.wake() }
            }
        }
        keyframe = false
        return BrowserEncodedFrame(accessUnit: Data([0, 0, 0, 1, 0x65, 1]), isKeyframe: true, captureMicros: 1,
                                   pixelWidth: request.pixelWidth, pixelHeight: request.pixelHeight)
    }

    func requestKeyframe() {
        keyframe = true
        wake()
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }
}

/// The browser channel needs no daemon.
struct EmptyDaemon: MobileDaemon {
    func workspaceState() async throws -> MobileWorkspaceState { MobileWorkspaceState(host: "h_mac1", workspaces: []) }
    func workspaceChanges() async -> AsyncStream<Void> { AsyncStream { _ in } }
    func perform(_ op: MobileDaemonOp, context: MobileOpContext) async throws -> MobileDaemonOpResult {
        throw MobileDaemonError(code: "proto.unsupported", message: "not in this test")
    }
    func attachTerminal(_ request: MobileTerminalAttachRequest) async throws -> any MobileTerminalAttachment {
        throw MobileDaemonError(code: "terminal.not_found", message: "not in this test")
    }
}
