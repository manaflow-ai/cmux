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
        /// Acceptor and peer changes, for an embedding app's status UI.
        public var onEvent: @Sendable (NativeHostEvent) -> Void
        /// Push: post attention events and Live Activity updates to the
        /// Worker with the host's credentials. Nil turns push off.
        public var attention: AttentionPublisher.Configuration?

        public init(locator: DaemonSocketLocator = DaemonSocketLocator(), guardrail: PathGuard = PathGuard(),
                    uploadsRoot: String? = nil, log: @escaping @Sendable (String) -> Void = { _ in },
                    onEvent: @escaping @Sendable (NativeHostEvent) -> Void = { _ in },
                    attention: AttentionPublisher.Configuration? = nil) {
            self.locator = locator
            self.guardrail = guardrail
            self.uploadsRoot = uploadsRoot
            self.log = log
            self.onEvent = onEvent
            self.attention = attention
        }
    }

    public let configuration: Configuration
    private let acceptors: [any HostAcceptor]
    private let router: ChannelRouter
    private var running = false
    /// Phones currently showing cmux; push alerts wait while any is.
    public let presence: PresenceBoard
    public let attention: AttentionPublisher?

    public init(acceptors: [any HostAcceptor], configuration: Configuration = Configuration()) {
        self.acceptors = acceptors
        self.configuration = configuration
        let locator = configuration.locator
        let presence = PresenceBoard()
        self.presence = presence
        let services = HostServices(guardrail: configuration.guardrail, uploadsRoot: configuration.uploadsRoot,
                                    daemonSocket: { locator.resolve() }, presence: presence)
        let attention = configuration.attention.map {
            AttentionPublisher(configuration: $0, locator: locator, presence: presence, log: configuration.log)
        }
        self.attention = attention
        router = ChannelRouter(services: services, locator: locator, log: configuration.log, onEvent: configuration.onEvent,
                               attention: attention)
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
        if let attention { Task { await attention.start() } }
    }

    public func stop() {
        guard running else { return }
        running = false
        for acceptor in acceptors {
            acceptor.stop()
            acceptor.setDelegate(nil)
        }
        router.closeAll()
        if let attention { Task { await attention.stop() } }
    }

    /// Phones with open channels.
    public var connectedPeers: [LinkPeer] { router.peers() }
}

/// What the host reports to an embedding app (`Configuration.onEvent`).
public enum NativeHostEvent: Sendable, Equatable {
    /// The signaling acceptor's state (listening once the Worker accepted the host).
    case acceptor(HostAcceptorState)
    /// A phone's link came up; `path` says direct or relay when known.
    case peerConnected(LinkPeer, LinkPathInfo?)
    case peerDisconnected(LinkPeer)
}

/// Routes accepted channels by label.
final class ChannelRouter: HostAcceptorDelegate {
    let services: HostServices
    let locator: DaemonSocketLocator
    let log: @Sendable (String) -> Void
    let onEvent: @Sendable (NativeHostEvent) -> Void
    let attention: AttentionPublisher?
    private let open = Mutex<[ObjectIdentifier: (channel: any LinkChannel, peer: LinkPeer)]>([:])

    init(services: HostServices, locator: DaemonSocketLocator, log: @escaping @Sendable (String) -> Void,
         onEvent: @escaping @Sendable (NativeHostEvent) -> Void = { _ in }, attention: AttentionPublisher? = nil) {
        self.services = services
        self.locator = locator
        self.log = log
        self.onEvent = onEvent
        self.attention = attention
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
                await services.serve(channel: channel, peer: peer.sid, log: log)
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
        onEvent(.peerConnected(peer, path))
    }

    func hostAcceptor(_ acceptor: any HostAcceptor, peerDidDisconnect peer: LinkPeer) {
        log("\(peer) disconnected")
        services.presence.clear(peer: peer.sid)
        onEvent(.peerDisconnected(peer))
    }

    func hostAcceptor(_ acceptor: any HostAcceptor, didReceiveAction action: JSONValue, from userID: String?) {
        guard let attention else {
            log("notification action ignored: push is off")
            return
        }
        Task { await attention.perform(action: action, userID: userID) }
    }

    func hostAcceptor(_ acceptor: any HostAcceptor, peerDidTimeOut peer: LinkPeer, idle: Duration) {
        log("\(peer) timed out (no traffic \(idle.components.seconds) s)")
    }

    func hostAcceptor(_ acceptor: any HostAcceptor, didChange state: HostAcceptorState) {
        log("acceptor \(type(of: acceptor)): \(state)")
        onEvent(.acceptor(state))
    }
}
