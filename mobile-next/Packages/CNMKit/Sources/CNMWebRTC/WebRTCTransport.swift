import CNMProtocol
import CNMTransport
import Foundation
@preconcurrency import WebRTC

/// One ICE server as the backend returns it (`GET /v1/ice`).
public struct ICEServer: Sendable, Hashable, Codable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    public static let cloudflareSTUN = ICEServer(urls: ["stun:stun.cloudflare.com:3478"])
}

public struct WebRTCOptions: Sendable {
    /// Called for every new link so short-lived TURN credentials stay fresh.
    public var iceServers: @Sendable () async -> [ICEServer]
    /// Forces TURN relay (used to verify the relay path).
    public var relayOnly: Bool
    public var connectTimeout: Duration

    public init(
        iceServers: @escaping @Sendable () async -> [ICEServer],
        relayOnly: Bool = false,
        connectTimeout: Duration = .seconds(25)
    ) {
        self.iceServers = iceServers
        self.relayOnly = relayOnly
        self.connectTimeout = connectTimeout
    }
}

/// Owns the process-wide WebRTC factory.
final class WebRTCEngine: @unchecked Sendable {
    static let shared = WebRTCEngine()
    let factory: RTCPeerConnectionFactory

    private init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }

    func makeConnection(options: WebRTCOptions, servers: [ICEServer], delegate: RTCPeerConnectionDelegate) -> RTCPeerConnection? {
        let config = RTCConfiguration()
        config.iceServers = servers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceTransportPolicy = options.relayOnly ? .relay : .all
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        return factory.peerConnection(with: config, constraints: constraints, delegate: delegate)
    }
}

/// A `PeerLink` on one RTCPeerConnection with two negotiated data channels
/// (id 0 control, id 1 bulk), so neither side waits for `didOpen` events.
public final class WebRTCLink: NSObject, PeerLink, @unchecked Sendable {
    public let remotePeerID: String
    public let session: String
    public let states: AsyncStream<LinkState>
    public let messages: AsyncStream<(Lane, Data)>
    private let stateContinuation: AsyncStream<LinkState>.Continuation
    private let messageContinuation: AsyncStream<(Lane, Data)>.Continuation
    private let signaling: SignalingChannel
    private let lock = NSLock()
    private var connection: RTCPeerConnection?
    private var control: RTCDataChannel?
    private var bulk: RTCDataChannel?
    private var pendingCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false
    private var closed = false
    private var openWaiters: [CheckedContinuation<Void, Error>] = []
    private var reportedConnected = false
    private var closeHandlers: [@Sendable () -> Void] = []

    /// Runs once when the link closes or fails (the state stream has one reader: the app).
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { closeHandlers.append(handler) }
    }

    private func runCloseHandlers() {
        let handlers: [@Sendable () -> Void] = lock.withLock {
            defer { closeHandlers.removeAll() }
            return closeHandlers
        }
        for handler in handlers { handler() }
    }

    init(remotePeerID: String, session: String, signaling: SignalingChannel) {
        self.remotePeerID = remotePeerID
        self.session = session
        self.signaling = signaling
        (states, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (messages, messageContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        super.init()
        stateContinuation.yield(.connecting)
    }

    func attach(_ connection: RTCPeerConnection) {
        let control = Self.makeChannel(connection, label: "control", id: 0)
        let bulk = Self.makeChannel(connection, label: "bulk", id: 1)
        control?.delegate = self
        bulk?.delegate = self
        lock.withLock {
            self.connection = connection
            self.control = control
            self.bulk = bulk
        }
    }

    private static func makeChannel(_ connection: RTCPeerConnection, label: String, id: Int32) -> RTCDataChannel? {
        let config = RTCDataChannelConfiguration()
        config.isNegotiated = true
        config.channelId = id
        config.isOrdered = true
        return connection.dataChannel(forLabel: label, configuration: config)
    }

    // MARK: PeerLink

    public func send(_ data: Data, on lane: Lane) throws {
        let channel = lock.withLock { lane == .control ? control : bulk }
        guard let channel, channel.readyState == .open else { throw TransportError("Channel not open") }
        guard channel.sendData(RTCDataBuffer(data: data, isBinary: lane == .bulk)) else {
            throw TransportError("Send failed")
        }
    }

    public func close() {
        let (connection, waiters, wasOpen): (RTCPeerConnection?, [CheckedContinuation<Void, Error>], Bool) = lock.withLock {
            let wasOpen = !closed
            closed = true
            defer {
                self.connection = nil
                openWaiters.removeAll()
            }
            return (self.connection, openWaiters, wasOpen)
        }
        guard wasOpen else { return }
        try? signaling.send(to: remotePeerID, session: session, payload: ["kind": "bye"])
        connection?.close()
        for waiter in waiters { waiter.resume(throwing: TransportError("Link closed")) }
        stateContinuation.yield(.disconnected(reason: nil))
        stateContinuation.finish()
        messageContinuation.finish()
        runCloseHandlers()
    }

    func fail(_ reason: String) {
        let waiters: [CheckedContinuation<Void, Error>] = lock.withLock {
            defer { openWaiters.removeAll() }
            return openWaiters
        }
        for waiter in waiters { waiter.resume(throwing: TransportError(reason)) }
        stateContinuation.yield(.disconnected(reason: reason))
        lock.withLock { closed = true }
        connection?.close()
        stateContinuation.finish()
        messageContinuation.finish()
        runCloseHandlers()
    }

    /// Waits until both channels are open.
    func waitUntilOpen(timeout: Duration) async throws {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.fail("Timed out connecting") }
        }
        defer { timeoutTask.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let ready: Bool? = lock.withLock {
                if closed { return nil }
                if control?.readyState == .open, bulk?.readyState == .open { return true }
                openWaiters.append(continuation)
                return false
            }
            switch ready {
            case .some(true): continuation.resume()
            case .none: continuation.resume(throwing: TransportError("Link closed"))
            case .some(false): break
            }
        }
    }

    // MARK: Signaling

    func handleSignal(_ payload: JSONValue) {
        guard let kind = payload["kind"]?.stringValue else { return }
        switch kind {
        case "answer":
            guard let sdp = payload["sdp"]?.stringValue else { return }
            setRemote(RTCSessionDescription(type: .answer, sdp: sdp)) { _ in }
        case "candidate":
            guard let sdp = payload["candidate"]?.stringValue else { return }
            let candidate = RTCIceCandidate(
                sdp: sdp,
                sdpMLineIndex: Int32(payload["sdpMLineIndex"]?.intValue ?? 0),
                sdpMid: payload["sdpMid"]?.stringValue
            )
            let connection: RTCPeerConnection? = lock.withLock {
                if !hasRemoteDescription {
                    pendingCandidates.append(candidate)
                    return nil
                }
                return self.connection
            }
            connection?.add(candidate) { _ in }
        case "bye":
            fail("Remote closed")
        default:
            break
        }
    }

    func setRemote(_ description: RTCSessionDescription, completion: @escaping @Sendable (Error?) -> Void) {
        guard let connection = lock.withLock({ self.connection }) else { return }
        connection.setRemoteDescription(description) { [weak self] error in
            guard let self else { return }
            if error == nil {
                let pending: [RTCIceCandidate] = self.lock.withLock {
                    self.hasRemoteDescription = true
                    defer { self.pendingCandidates.removeAll() }
                    return self.pendingCandidates
                }
                for candidate in pending { connection.add(candidate) { _ in } }
            }
            completion(error)
        }
    }

    var peerConnection: RTCPeerConnection? { lock.withLock { connection } }

    private func channelsMaybeOpen() {
        let (open, waiters): (Bool, [CheckedContinuation<Void, Error>]) = lock.withLock {
            let open = control?.readyState == .open && bulk?.readyState == .open
            guard open else { return (false, []) }
            defer { openWaiters.removeAll() }
            return (true, openWaiters)
        }
        guard open else { return }
        for waiter in waiters { waiter.resume() }
        reportRoute()
    }

    /// Reads the selected candidate pair to say whether the link is direct or
    /// relayed through TURN.
    private func reportRoute(attempt: Int = 0) {
        guard let connection = peerConnection else { return }
        connection.statistics { [weak self] report in
            guard let self else { return }
            var localCandidates: [String: String] = [:]
            var remoteCandidates: [String: String] = [:]
            var selectedPair: (local: String, remote: String)?
            for (_, stat) in report.statistics {
                switch stat.type {
                case "local-candidate":
                    localCandidates[stat.id] = stat.values["candidateType"] as? String
                case "remote-candidate":
                    remoteCandidates[stat.id] = stat.values["candidateType"] as? String
                case "candidate-pair":
                    let nominated = (stat.values["nominated"] as? NSNumber)?.boolValue ?? false
                    let state = stat.values["state"] as? String
                    if nominated, state == "succeeded",
                       let local = stat.values["localCandidateId"] as? String,
                       let remote = stat.values["remoteCandidateId"] as? String
                    {
                        selectedPair = (local, remote)
                    }
                default:
                    break
                }
            }
            if selectedPair == nil, attempt < 8 {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { self.reportRoute(attempt: attempt + 1) }
                return
            }
            let route: String
            if let selectedPair {
                let local = localCandidates[selectedPair.local] ?? "?"
                let remote = remoteCandidates[selectedPair.remote] ?? "?"
                route = (local == "relay" || remote == "relay") ? "relay" : "direct (\(local)/\(remote))"
            } else {
                route = "direct"
            }
            let first = self.lock.withLock {
                defer { self.reportedConnected = true }
                return !self.reportedConnected
            }
            if first { self.stateContinuation.yield(.connected(route: route)) }
        }
    }
}

extension WebRTCLink: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open: channelsMaybeOpen()
        case .closed:
            if !lock.withLock({ closed }) { fail("Channel closed") }
        default: break
        }
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let lane: Lane = dataChannel.channelId == 0 ? .control : .bulk
        messageContinuation.yield((lane, buffer.data))
    }
}

extension WebRTCLink: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .failed: fail("Connection failed")
        default: break
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .failed: fail("Connection failed")
        case .closed: if !lock.withLock({ closed }) { fail("Connection closed") }
        default: break
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let payload: JSONValue = [
            "kind": "candidate",
            "candidate": .string(candidate.sdp),
            "sdpMid": candidate.sdpMid.map(JSONValue.string) ?? .null,
            "sdpMLineIndex": .number(Double(candidate.sdpMLineIndex)),
        ]
        try? signaling.send(to: remotePeerID, session: session, payload: payload)
    }
}

/// Phone side: dials a host through the signal hub.
public final class WebRTCDialer: PeerDialer, @unchecked Sendable {
    private let hub: SignalHub
    private let options: WebRTCOptions
    private let lock = NSLock()
    private var links: [String: WebRTCLink] = [:]

    public init(hub: SignalHub, options: WebRTCOptions) {
        self.hub = hub
        self.options = options
        Task { [weak self] in
            guard let events = self?.hub.subscribe() else { return }
            for await event in events {
                guard let self else { return }
                switch event {
                case .signal(_, let session, let payload):
                    self.lock.withLock { self.links[session] }?.handleSignal(payload)
                case .peerOffline(let peer):
                    let affected = self.lock.withLock { self.links.values.filter { $0.remotePeerID == peer } }
                    for link in affected { link.fail("Mac is offline") }
                default:
                    break
                }
            }
        }
    }

    public func dial(peerID: String) async throws -> PeerLink {
        let session = UUID().uuidString.lowercased()
        let link = WebRTCLink(remotePeerID: peerID, session: session, signaling: hub.channel)
        let servers = await options.iceServers()
        guard let connection = WebRTCEngine.shared.makeConnection(options: options, servers: servers, delegate: link) else {
            throw TransportError("Could not create a peer connection")
        }
        link.attach(connection)
        lock.withLock { links[session] = link }
        link.onClose { [weak self] in
            self?.lock.withLock { _ = self?.links.removeValue(forKey: session) }
        }

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? TransportError("No offer")) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(offer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        try hub.channel.send(to: peerID, session: session, payload: ["kind": "offer", "sdp": .string(offer.sdp)])
        do {
            try await link.waitUntilOpen(timeout: options.connectTimeout)
        } catch {
            link.close()
            throw error
        }
        return link
    }
}

/// Host side: answers offers from the user's phones.
public final class WebRTCAcceptor: PeerAcceptor, @unchecked Sendable {
    public let incoming: AsyncStream<PeerLink>
    private let continuation: AsyncStream<PeerLink>.Continuation
    private let hub: SignalHub
    private let options: WebRTCOptions
    private let lock = NSLock()
    private var links: [String: WebRTCLink] = [:]

    public init(hub: SignalHub, options: WebRTCOptions) {
        self.hub = hub
        self.options = options
        (incoming, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        Task { [weak self] in
            guard let events = self?.hub.subscribe() else { return }
            for await event in events {
                guard let self else { return }
                if case .signal(let from, let session, let payload) = event {
                    await self.handle(from: from, session: session, payload: payload)
                }
            }
        }
    }

    private func handle(from: String, session: String, payload: JSONValue) async {
        if let link = lock.withLock({ links[session] }) {
            link.handleSignal(payload)
            return
        }
        guard payload["kind"]?.stringValue == "offer", let sdp = payload["sdp"]?.stringValue else { return }
        let link = WebRTCLink(remotePeerID: from, session: session, signaling: hub.channel)
        lock.withLock { links[session] = link }
        let servers = await options.iceServers()
        guard let connection = WebRTCEngine.shared.makeConnection(options: options, servers: servers, delegate: link) else {
            link.fail("Could not create a peer connection")
            return
        }
        link.attach(connection)
        link.onClose { [weak self] in
            self?.lock.withLock { _ = self?.links.removeValue(forKey: session) }
        }
        link.setRemote(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self, weak link] error in
            guard let self, let link else { return }
            if let error {
                link.fail("Bad offer: \(error.localizedDescription)")
                return
            }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            connection.answer(for: constraints) { answer, error in
                guard let answer else {
                    link.fail("No answer: \(error?.localizedDescription ?? "")")
                    return
                }
                connection.setLocalDescription(answer) { error in
                    if let error {
                        link.fail("Answer failed: \(error.localizedDescription)")
                        return
                    }
                    try? self.hub.channel.send(to: from, session: session, payload: ["kind": "answer", "sdp": .string(answer.sdp)])
                }
            }
        }
        Task { [continuation] in
            do {
                try await link.waitUntilOpen(timeout: self.options.connectTimeout)
                continuation.yield(link)
            } catch {
                link.close()
            }
        }
    }
}
