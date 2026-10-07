import CmuxBrowserStream
import CmuxiOSBrowserCore
import CmuxiOSFeatureKit
import CmuxLink
import CmuxLinkTesting
import CmuxMobileHost
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
    let phone: LinkSession
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
        let phone = LinkSession(peer: LinkPeer(hostID: hostID),
                                selector: PathSelector(carriers: [network.carrier(kind: .direct, path: .direct)],
                                                       policy: PathPolicy(preferenceWindow: .milliseconds(5), upgradeRetry: nil)),
                                configuration: fast)
        await phone.connect()
        let proof = try DeviceProof(install: install, keyID: "k1", issuedAt: Int64(Date().timeIntervalSince1970 * 1000),
                                    hostID: hostID, sessionID: phone.sessionID) { try key.signature(for: $0).rawRepresentation }
        let hello = HelloFrame(caps: ["device-proof"], client: HelloClient(install: install, platform: "ios", appVersion: "1.0"))
        guard case .object(var object) = try MobileFrame.hello(hello).jsonValue else { throw TimeoutError() }
        object["auth"] = proof.jsonValue
        let session = try await phone.openChannel(ChannelDescriptor(stream: "cmux.mobile/session", reliability: .reliableOrdered,
                                                                    priority: .control))
        let channel = MobileChannel(id: 0, link: session)
        try await channel.send(json: .object(object))
        guard case .json(let reply) = await channel.receive(), reply["t"]?.stringValue == "hello.ok" else { throw TimeoutError() }
        return BrowserHostHarness(host: host, phone: phone, pages: pages)
    }

    func shutdown() async {
        await phone.close()
        await host.stop()
    }

    var source: LinkBrowserStreamSource {
        LinkBrowserStreamSource(links: StubLinks(session: HarnessLink(link: phone)), directory: StubDirectory(),
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

final class HarnessLink: MobileSessionLink {
    let link: any CmuxLink
    private let ids = HarnessChannelIDs()

    init(link: any CmuxLink) {
        self.link = link
    }

    func allocateChannelID() async -> UInt32 { await ids.take() }
}

actor HarnessChannelIDs {
    private var next: UInt32 = 1

    func take() -> UInt32 {
        defer { next += 2 }
        return next
    }
}

struct StubLinks: MobileSessionLinkProvider {
    let session: any MobileSessionLink

    func session(toHost hostID: String) async throws -> any MobileSessionLink { session }
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
