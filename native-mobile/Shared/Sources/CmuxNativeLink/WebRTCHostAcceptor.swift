import Foundation
import CmuxNativeWire
import Synchronization
@preconcurrency import WebRTC

/// Host side of the WebRTC link: holds the signaling socket to the Worker,
/// answers each phone's offer (per `sid`), and hands the phone's data
/// channels to the delegate. Reconnects signaling with backoff; established
/// peers survive a signaling outage.
public final class WebRTCHostAcceptor: HostAcceptor {
    public struct Configuration: Sendable {
        public var apiBase: URL
        public var hostID: String
        public var hostSecret: String
        public var relayOnly: Bool

        public init(apiBase: URL, hostID: String, hostSecret: String, relayOnly: Bool = false) {
            self.apiBase = apiBase
            self.hostID = hostID
            self.hostSecret = hostSecret
            self.relayOnly = relayOnly
        }
    }

    private let engine: HostAcceptorEngine

    public convenience init(configuration: Configuration) {
        let api = WorkerAPI(baseURL: configuration.apiBase)
        let secret = configuration.hostSecret
        self.init(
            signaling: api.signalingConnector(hostID: configuration.hostID, token: { secret }),
            iceServers: api.iceServerProvider(token: { secret }),
            relayOnly: configuration.relayOnly
        )
    }

    public init(signaling: @escaping SignalingConnector, iceServers: @escaping IceServerProvider, relayOnly: Bool = false) {
        engine = HostAcceptorEngine(signaling: signaling, iceServers: iceServers, relayOnly: relayOnly)
        engine.owner.withLock { $0 = WeakAcceptor(self) }
    }

    deinit { engine.shutdown() }

    public func setDelegate(_ delegate: (any HostAcceptorDelegate)?) {
        engine.delegate.withLock { $0 = delegate }
    }

    public func start() {
        Task { [engine] in await engine.start() }
    }

    public func stop() { engine.shutdown() }

    /// Currently attached phones.
    public var peers: [LinkPeer] { engine.peerList.withLock { $0 } }
}

struct WeakAcceptor: Sendable {
    weak var value: WebRTCHostAcceptor?
    init(_ value: WebRTCHostAcceptor) { self.value = value }
}

final class HostPeer: Sendable {
    let peer: LinkPeer
    let pc: RTCPeerConnection
    let proxy: PeerEventProxy
    let channels = Mutex<[WebRTCLinkChannel]>([])
    let state = Mutex<(connected: Bool, remoteSet: Bool, pending: [IceCandidate], closed: Bool)>((false, false, [], false))

    init(peer: LinkPeer, pc: RTCPeerConnection, proxy: PeerEventProxy) {
        self.peer = peer
        self.pc = pc
        self.proxy = proxy
    }

    var isConnected: Bool { state.withLock { $0.connected } }

    func close() {
        let first = state.withLock { s -> Bool in
            defer { s.closed = true }
            return !s.closed
        }
        guard first else { return }
        let all = channels.withLock { c in
            defer { c = [] }
            return c
        }
        for channel in all { channel.close() }
        pc.close()
        proxy.finish()
    }
}

actor HostAcceptorEngine {
    static let maximumPeers = 16

    nonisolated let delegate = Mutex<(any HostAcceptorDelegate)?>(nil)
    nonisolated let owner = Mutex<WeakAcceptor?>(nil)
    nonisolated let peerList = Mutex<[LinkPeer]>([])
    private nonisolated let closedFlag = Atomic<Bool>(false)
    private let signalingConnector: SignalingConnector
    private let iceProvider: IceServerProvider
    private let relayOnly: Bool
    private var supervisor: Task<Void, Never>?
    private var signaling: (any SignalingTransport)?
    private var peers: [String: HostPeer] = [:]
    private var pendingCandidates: [String: [IceCandidate]] = [:]

    init(signaling: @escaping SignalingConnector, iceServers: @escaping IceServerProvider, relayOnly: Bool) {
        self.signalingConnector = signaling
        self.iceProvider = iceServers
        self.relayOnly = relayOnly
    }

    private var isClosed: Bool { closedFlag.load(ordering: .acquiring) }

    func start() {
        guard supervisor == nil, !isClosed else { return }
        supervisor = Task { await self.supervise() }
    }

    nonisolated func shutdown() {
        guard !closedFlag.exchange(true, ordering: .acquiringAndReleasing) else { return }
        Task { await self.teardown() }
    }

    private func teardown() {
        supervisor?.cancel()
        signaling?.close()
        signaling = nil
        for peer in peers.values { peer.close() }
        let gone = peers.values.map(\.peer)
        peers.removeAll()
        publishPeers()
        for peer in gone { notify { $0.hostAcceptor($1, peerDidDisconnect: peer) } }
        notify { $0.hostAcceptor($1, didChange: .stopped) }
    }

    private nonisolated func notify(_ body: (any HostAcceptorDelegate, any HostAcceptor) -> Void) {
        guard let d = delegate.withLock({ $0 }), let o = owner.withLock({ $0?.value }) else { return }
        body(d, o)
    }

    private func publishPeers() {
        let list = peers.values.map(\.peer)
        peerList.withLock { $0 = list }
    }

    // MARK: Signaling

    private func supervise() async {
        var backoff = Backoff()
        var first = true
        while !isClosed, !Task.isCancelled {
            notify { $0.hostAcceptor($1, didChange: first ? .connecting : .reconnecting("signaling lost")) }
            first = false
            do {
                let transport = try await signalingConnector()
                signaling = transport
                backoff.reset()
                notify { $0.hostAcceptor($1, didChange: .listening) }
                for await message in transport.messages {
                    if isClosed { break }
                    await handle(message)
                }
                if signaling === transport { signaling = nil }
            } catch let error as LinkError where ["http_401", "http_403", "http_404"].contains(error.code) {
                notify { $0.hostAcceptor($1, didChange: .failed(error.message)) }
                return
            } catch {
                notify { $0.hostAcceptor($1, didChange: .reconnecting("\(error)")) }
            }
            if isClosed || Task.isCancelled { break }
            try? await Task.sleep(for: backoff.next())
        }
    }

    private func send(_ message: SignalMessage) async {
        try? await signaling?.send(message)
    }

    private func handle(_ message: SignalMessage) async {
        guard let sid = message.sid else { return }
        switch message.t {
        case .offer:
            guard let sdp = message.sdp else { return }
            await handleOffer(sid: sid, userID: message.userID, sdp: sdp)
        case .ice:
            guard let candidate = message.candidate else { return }
            if let peer = peers[sid] {
                let ready = peer.state.withLock { s -> Bool in
                    if !s.remoteSet { s.pending.append(candidate) }
                    return s.remoteSet
                }
                if ready { try? await peer.pc.addRemote(candidate) }
            } else {
                pendingCandidates[sid, default: []].append(candidate)
                if pendingCandidates.count > 64 { pendingCandidates.removeAll() }
            }
        case .bye:
            guard let peer = peers[sid] else { return }
            // The Worker reports a phone's signaling socket dropping as a bye;
            // a connected peer does not need signaling and stays.
            if message.reason == "phone_disconnected", peer.isConnected { return }
            removePeer(sid)
        default:
            return
        }
    }

    private func handleOffer(sid: String, userID: String?, sdp: String) async {
        let peer: HostPeer
        if let existing = peers[sid] {
            peer = existing
        } else {
            if peers.count >= Self.maximumPeers, let oldest = peers.first(where: { !$0.value.isConnected })?.key ?? peers.keys.first {
                removePeer(oldest)
            }
            guard let created = await makePeer(sid: sid, userID: userID) else {
                await send(SignalMessage(t: .bye, sid: sid, reason: "host_error"))
                return
            }
            peer = created
        }
        do {
            peer.state.withLock { $0.remoteSet = false }
            try await peer.pc.applyRemote(RTCSessionDescription(type: .offer, sdp: sdp))
            let pending = peer.state.withLock { s -> [IceCandidate] in
                s.remoteSet = true
                defer { s.pending = [] }
                return s.pending
            } + (pendingCandidates.removeValue(forKey: sid) ?? [])
            for candidate in pending { try? await peer.pc.addRemote(candidate) }
            let answer = try await peer.pc.makeAnswer()
            try await peer.pc.applyLocal(answer)
            await send(.answer(sid: sid, sdp: answer.sdp))
        } catch {
            await send(SignalMessage(t: .bye, sid: sid, reason: "bad_offer"))
            removePeer(sid)
        }
    }

    private func makePeer(sid: String, userID: String?) async -> HostPeer? {
        guard let ice = try? await iceProvider() else { return nil }
        let linkPeer = LinkPeer(sid: sid, userID: userID)
        let holder = Mutex<HostPeer?>(nil)
        let proxy = PeerEventProxy(onDataChannel: { dc in
            // Runs on WebRTC's signaling thread before any message arrives.
            let channel = WebRTCLinkChannel(channel: dc)
            guard let peer = holder.withLock({ $0 }) else {
                channel.close()
                return
            }
            peer.channels.withLock { $0.append(channel) }
            guard dc.label != PhoneLinkEngine.controlLabel else { return }
            if let d = self.delegate.withLock({ $0 }), let o = self.owner.withLock({ $0?.value }) {
                d.hostAcceptor(o, didOpen: channel, from: linkPeer)
            } else {
                channel.close()
            }
        })
        guard let pc = try? RTCEnvironment.shared.makePeerConnection(iceServers: ice, relayOnly: relayOnly, delegate: proxy) else {
            return nil
        }
        let peer = HostPeer(peer: linkPeer, pc: pc, proxy: proxy)
        holder.withLock { $0 = peer }
        peers[sid] = peer
        publishPeers()
        Task { await self.pump(peer) }
        return peer
    }

    private func pump(_ peer: HostPeer) async {
        let sid = peer.peer.sid
        var watchdog: Task<Void, Never>? = Task {
            try? await Task.sleep(for: .seconds(45))
            if !Task.isCancelled, !peer.isConnected { self.removePeer(sid, ifSame: peer) }
        }
        for await event in peer.proxy.events {
            switch event {
            case .candidate(let candidate):
                await send(.ice(sid: sid, candidate: candidate))
            case .connectionState(let state):
                switch state {
                case .connected:
                    watchdog?.cancel()
                    watchdog = nil
                    peer.state.withLock { $0.connected = true }
                    let info = await peer.pc.selectedPath()
                    notify { $0.hostAcceptor($1, peerDidConnect: peer.peer, path: info) }
                case .disconnected:
                    peer.state.withLock { $0.connected = false }
                    // The phone drives ICE restarts; give up after 60 s.
                    watchdog?.cancel()
                    watchdog = Task {
                        try? await Task.sleep(for: .seconds(60))
                        if !Task.isCancelled, !peer.isConnected { self.removePeer(sid, ifSame: peer) }
                    }
                case .failed, .closed:
                    watchdog?.cancel()
                    removePeer(sid, ifSame: peer)
                    return
                default:
                    break
                }
            case .dataChannel, .selectedPairChanged:
                break
            }
        }
        watchdog?.cancel()
    }

    private func removePeer(_ sid: String, ifSame expected: HostPeer? = nil) {
        guard let peer = peers[sid], expected == nil || peer === expected else { return }
        peers.removeValue(forKey: sid)
        publishPeers()
        peer.close()
        notify { $0.hostAcceptor($1, peerDidDisconnect: peer.peer) }
    }
}
