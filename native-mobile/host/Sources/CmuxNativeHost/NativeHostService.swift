import Foundation
public import CmuxNativeLink
import CmuxNativeWire
import Synchronization

/// The embeddable host bridge: accepts phones through one or more
/// `HostAcceptor`s and serves their channels (`svc` and `daemon:<uuid>`).
///
/// The cmux-next Mac app links this and starts it with its own daemon socket;
/// the `cmux-native-host` CLI wraps it.
public actor NativeHostService {
    public struct Configuration: Sendable {
        /// Daemon socket discovery, evaluated per daemon channel so a daemon
        /// restart is picked up.
        public var locator: DaemonSocketLocator
        public var guardrail: PathGuard
        public var uploadsRoot: String?
        public var log: @Sendable (String) -> Void

        public init(locator: DaemonSocketLocator = DaemonSocketLocator(), guardrail: PathGuard = PathGuard(),
                    uploadsRoot: String? = nil, log: @escaping @Sendable (String) -> Void = { _ in }) {
            self.locator = locator
            self.guardrail = guardrail
            self.uploadsRoot = uploadsRoot
            self.log = log
        }
    }

    public let configuration: Configuration
    private let acceptors: [any HostAcceptor]
    private let router: ChannelRouter
    private var running = false

    public init(acceptors: [any HostAcceptor], configuration: Configuration = Configuration()) {
        self.acceptors = acceptors
        self.configuration = configuration
        let locator = configuration.locator
        let services = HostServices(guardrail: configuration.guardrail, uploadsRoot: configuration.uploadsRoot,
                                    daemonSocket: { locator.resolve() })
        router = ChannelRouter(services: services, locator: locator, log: configuration.log)
    }

    public init(acceptor: any HostAcceptor, configuration: Configuration = Configuration()) {
        self.init(acceptors: [acceptor], configuration: configuration)
    }

    public func start() {
        guard !running else { return }
        running = true
        for acceptor in acceptors {
            acceptor.setDelegate(router)
            acceptor.start()
        }
        configuration.log("native host started; daemon socket: \(configuration.locator.resolve() ?? "not found")")
    }

    public func stop() {
        guard running else { return }
        running = false
        for acceptor in acceptors {
            acceptor.stop()
            acceptor.setDelegate(nil)
        }
        router.closeAll()
    }

    /// Phones with open channels.
    public var connectedPeers: [LinkPeer] { router.peers() }
}

/// Routes accepted channels by label.
final class ChannelRouter: HostAcceptorDelegate {
    let services: HostServices
    let locator: DaemonSocketLocator
    let log: @Sendable (String) -> Void
    private let open = Mutex<[ObjectIdentifier: (channel: any LinkChannel, peer: LinkPeer)]>([:])

    init(services: HostServices, locator: DaemonSocketLocator, log: @escaping @Sendable (String) -> Void) {
        self.services = services
        self.locator = locator
        self.log = log
    }

    func peers() -> [LinkPeer] {
        Array(Set(open.withLock { $0.values.map(\.peer) }))
    }

    func closeAll() {
        let all = open.withLock { o in
            defer { o = [:] }
            return o.values.map(\.channel)
        }
        for channel in all { channel.close() }
    }

    func hostAcceptor(_ acceptor: any HostAcceptor, didOpen channel: any LinkChannel, from peer: LinkPeer) {
        let key = ObjectIdentifier(channel)
        open.withLock { $0[key] = (channel, peer) }
        let label = channel.label
        log("\(peer) opened \(label)")
        Task {
            defer { _ = self.open.withLock { $0.removeValue(forKey: key) } }
            if label == "svc" {
                await services.serve(channel: channel, log: log)
            } else if label.hasPrefix("daemon:") {
                let policy = DaemonChannelPolicy(deviceID: peer.userID ?? peer.sid)
                let bridge = DaemonChannelBridge(socketPath: locator.resolve(), policy: policy, log: log)
                _ = await bridge.run(channel: channel)
            } else {
                log("refusing unknown channel \(label)")
                channel.close()
            }
        }
    }

    func hostAcceptor(_ acceptor: any HostAcceptor, peerDidConnect peer: LinkPeer, path: LinkPathInfo?) {
        let detail = path.map { "\($0.path) local=\($0.localCandidateType ?? "?") remote=\($0.remoteCandidateType ?? "?")" } ?? "unknown"
        log("\(peer) connected (\(detail))")
    }

    func hostAcceptor(_ acceptor: any HostAcceptor, peerDidDisconnect peer: LinkPeer) {
        log("\(peer) disconnected")
    }

    func hostAcceptor(_ acceptor: any HostAcceptor, didChange state: HostAcceptorState) {
        log("acceptor \(type(of: acceptor)): \(state)")
    }
}
