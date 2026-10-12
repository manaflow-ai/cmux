import Foundation
public import CmuxNativeWire
import Synchronization
@preconcurrency import WebRTC

/// Phone side of the WebRTC link: signals through the Worker, offers a peer
/// connection to the host, and keeps it alive with ICE restarts and full
/// reconnects (exponential backoff).
public final class WebRTCHostLink: HostLink {
    public struct Configuration: Sendable {
        public var apiBase: URL
        public var hostID: String
        /// Returns the current session token (read on every reconnect).
        public var token: @Sendable () -> String
        /// Force TURN relay (testing).
        public var relayOnly: Bool

        public init(apiBase: URL, hostID: String, token: @escaping @Sendable () -> String) {
            self.apiBase = apiBase
            self.hostID = hostID
            self.token = token
            self.relayOnly = false
        }
    }

    private let engine: PhoneLinkEngine

    public convenience init(configuration: Configuration) {
        let api = WorkerAPI(baseURL: configuration.apiBase)
        self.init(
            signaling: api.signalingConnector(hostID: configuration.hostID, token: configuration.token),
            iceServers: api.iceServerProvider(token: configuration.token),
            relayOnly: configuration.relayOnly
        )
    }

    /// Custom signaling and ICE (tests, in-process e2e).
    public init(signaling: @escaping SignalingConnector, iceServers: @escaping IceServerProvider, relayOnly: Bool = false) {
        engine = PhoneLinkEngine(signaling: signaling, iceServers: iceServers, relayOnly: relayOnly)
        Task { [engine] in await engine.start() }
    }

    deinit { engine.shutdown() }

    public var state: AsyncStream<LinkState> { engine.broadcaster.stream() }

    /// The latest state, without subscribing.
    public var currentState: LinkState { engine.broadcaster.current }

    /// Selected path detail (candidate types, RTT), refreshed every few seconds.
    public var pathInfo: LinkPathInfo? { engine.pathInfo.withLock { $0 } }

    public func openChannel(label: String) async throws -> any LinkChannel {
        try await engine.openChannel(label: label)
    }

    public func close() { engine.shutdown() }
}

// MARK: - Engine

final class PhoneSession: Sendable {
    let sid: String
    let pc: RTCPeerConnection
    let channels = Mutex<[ObjectIdentifier: WebRTCLinkChannel]>([:])

    init(sid: String, pc: RTCPeerConnection) {
        self.sid = sid
        self.pc = pc
    }

    func closeChannels() {
        let all = channels.withLock { c in
            defer { c = [:] }
            return Array(c.values)
        }
        for channel in all { channel.close() }
    }
}

actor PhoneLinkEngine {
    static let controlLabel = "_ctl"

    nonisolated let broadcaster = StateBroadcaster<LinkState>(.connecting)
    nonisolated let pathInfo = Mutex<LinkPathInfo?>(nil)
    private nonisolated let closedFlag = Atomic<Bool>(false)
    private let signalingConnector: SignalingConnector
    private let iceProvider: IceServerProvider
    private let relayOnly: Bool
    private var supervisor: Task<Void, Never>?
    private var session: PhoneSession?
    private var connectedGate = AsyncGate()
    // Per-session signaling state (one session at a time).
    private var signaling: (any SignalingTransport)?
    private var remoteSet = false

    private func sendSignal(_ message: SignalMessage) async {
        guard let signaling else { return }
        try? await signaling.send(message)
    }

    private func sendOffer(_ pc: RTCPeerConnection, sid: String, iceRestart: Bool) async throws {
        let offer = try await pc.makeOffer(iceRestart: iceRestart)
        try await pc.applyLocal(offer)
        remoteSet = false
        await sendSignal(.offer(sid: sid, sdp: offer.sdp))
    }

    init(signaling: @escaping SignalingConnector, iceServers: @escaping IceServerProvider, relayOnly: Bool) {
        self.signalingConnector = signaling
        self.iceProvider = iceServers
        self.relayOnly = relayOnly
    }

    func start() {
        guard supervisor == nil, !closedFlag.load(ordering: .acquiring) else { return }
        supervisor = Task { await self.supervise() }
    }

    nonisolated func shutdown() {
        guard !closedFlag.exchange(true, ordering: .acquiringAndReleasing) else { return }
        broadcaster.finish(with: .closed)
        Task { await self.teardown() }
    }

    private func teardown() {
        supervisor?.cancel()
        connectedGate.fail(.closed)
    }

    private var isClosed: Bool { closedFlag.load(ordering: .acquiring) }

    func openChannel(label: String) async throws -> any LinkChannel {
        guard label != Self.controlLabel else { throw LinkError(code: "bad_label", message: "\(label) is reserved") }
        while true {
            if isClosed { throw LinkError.closed }
            if case .failed(let message) = broadcaster.current { throw LinkError(code: "failed", message: message) }
            if let session, connectedGate.isOpen {
                guard let dc = session.pc.dataChannel(forLabel: label, configuration: RTCEnvironment.channelConfiguration()) else {
                    throw LinkError(code: "webrtc", message: "could not create data channel \(label)")
                }
                let key = ObjectIdentifier(dc)
                let channel = WebRTCLinkChannel(channel: dc, onClose: { [weak session] in
                    _ = session?.channels.withLock { $0.removeValue(forKey: key) }
                })
                session.channels.withLock { $0[key] = channel }
                try await channel.opened.wait(timeout: .seconds(20), what: "channel \(label) open")
                return channel
            }
            try await connectedGate.wait()
        }
    }

    // MARK: Supervision

    private enum Outcome {
        case ended(wasConnected: Bool, reason: String)
        case fatal(String)
    }

    private func supervise() async {
        var backoff = Backoff()
        var first = true
        while !isClosed, !Task.isCancelled {
            broadcaster.send(first ? .connecting : .reconnecting)
            first = false
            let outcome = await runSession()
            if isClosed || Task.isCancelled { break }
            switch outcome {
            case .fatal(let message):
                broadcaster.finish(with: .failed(message))
                connectedGate.fail(LinkError(code: "failed", message: message))
                return
            case .ended(let wasConnected, _):
                if wasConnected { backoff.reset() }
            }
            broadcaster.send(.reconnecting)
            try? await Task.sleep(for: backoff.next())
        }
    }

    private enum Event: Sendable {
        case peer(PeerEvent)
        case signal(SignalMessage)
        case signalingClosed
        case signalingRestored(any SignalingTransport)
        case iceRestartDue
        case connectDeadline
        case refreshPath
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func runSession() async -> Outcome {
        let ice: [IceServerConfig]
        signaling = nil
        remoteSet = false
        do {
            ice = try await iceProvider()
            signaling = try await signalingConnector()
        } catch let failure as WorkerAPI.Failure where [401, 403, 404].contains(failure.status) {
            return .fatal(failure.description)
        } catch let error as LinkError where ["http_401", "http_403", "http_404"].contains(error.code) {
            return .fatal(error.message)
        } catch {
            return .ended(wasConnected: false, reason: "\(error)")
        }

        let sid = UUID().uuidString.lowercased()
        let proxy = PeerEventProxy()
        let pc: RTCPeerConnection
        do {
            pc = try RTCEnvironment.shared.makePeerConnection(iceServers: ice, relayOnly: relayOnly, delegate: proxy)
        } catch {
            signaling?.close()
            return .fatal("\(error)")
        }
        let session = PhoneSession(sid: sid, pc: pc)
        // A data channel before the offer puts SCTP in the SDP.
        let control = pc.dataChannel(forLabel: Self.controlLabel, configuration: RTCEnvironment.channelConfiguration())

        let (events, sink) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        var helpers: [Task<Void, Never>] = []
        func pumpSignaling(_ transport: any SignalingTransport) -> Task<Void, Never> {
            Task {
                for await message in transport.messages { sink.yield(.signal(message)) }
                sink.yield(.signalingClosed)
            }
        }
        helpers.append(Task {
            for await event in proxy.events { sink.yield(.peer(event)) }
        })
        helpers.append(pumpSignaling(signaling!))
        helpers.append(Task {
            try? await Task.sleep(for: .seconds(30))
            sink.yield(.connectDeadline)
        })

        var connected = false
        var everConnected = false
        var pendingRemote: [IceCandidate] = []
        var restartTask: Task<Void, Never>?
        var refreshTask: Task<Void, Never>?
        var signalingRetry: Task<Void, Never>?
        var endReason = "ended"

        do {
            try await sendOffer(pc, sid: sid, iceRestart: false)
        } catch {
            endReason = "offer failed: \(error)"
            sink.finish()
        }

        loop: for await event in events {
            if isClosed { break }
            switch event {
            case .signal(let message):
                if let messageSID = message.sid, messageSID != sid { continue }
                switch message.t {
                case .answer:
                    guard let sdp = message.sdp else { continue }
                    do {
                        try await pc.applyRemote(RTCSessionDescription(type: .answer, sdp: sdp))
                        remoteSet = true
                        for candidate in pendingRemote { try? await pc.addRemote(candidate) }
                        pendingRemote.removeAll()
                    } catch {
                        endReason = "answer rejected: \(error)"
                        break loop
                    }
                case .ice:
                    guard let candidate = message.candidate else { continue }
                    if remoteSet { try? await pc.addRemote(candidate) } else { pendingRemote.append(candidate) }
                case .bye:
                    endReason = "bye: \(message.reason ?? "host")"
                    break loop
                case .error:
                    if message.code == "host_offline" || message.code == "unknown_sid" || message.code == "sid_in_use" {
                        endReason = message.code ?? "error"
                        if !connected { break loop }
                    }
                case .presence:
                    if message.online == false, !connected {
                        endReason = "host offline"
                        break loop
                    }
                default:
                    continue
                }
            case .signalingClosed:
                signaling = nil
                guard connected else {
                    endReason = "signaling closed"
                    break loop
                }
                // Keep the peer; restore signaling for later ICE restarts.
                signalingRetry?.cancel()
                let connector = signalingConnector
                signalingRetry = Task {
                    var backoff = Backoff()
                    while !Task.isCancelled {
                        if let restored = try? await connector() {
                            sink.yield(.signalingRestored(restored))
                            return
                        }
                        try? await Task.sleep(for: backoff.next())
                    }
                }
            case .signalingRestored(let restored):
                signaling = restored
                helpers.append(pumpSignaling(restored))
            case .peer(.candidate(let candidate)):
                await sendSignal(.ice(sid: sid, candidate: candidate))
            case .peer(.connectionState(let state)):
                switch state {
                case .connected:
                    connected = true
                    everConnected = true
                    restartTask?.cancel()
                    self.session = session
                    if !connectedGate.isOpen {
                        if connectedGate.isResolved { connectedGate = AsyncGate() }
                        connectedGate.open()
                    }
                    let info = await pc.selectedPath()
                    pathInfo.withLock { $0 = info }
                    broadcaster.send(.connected(info?.path ?? .unknown))
                    refreshTask?.cancel()
                    refreshTask = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(5))
                            sink.yield(.refreshPath)
                        }
                    }
                case .disconnected:
                    connected = false
                    broadcaster.send(.reconnecting)
                    restartTask?.cancel()
                    restartTask = Task {
                        try? await Task.sleep(for: .seconds(2))
                        if !Task.isCancelled { sink.yield(.iceRestartDue) }
                    }
                case .failed:
                    endReason = "peer connection failed"
                    break loop
                case .closed:
                    endReason = "peer connection closed"
                    break loop
                default:
                    continue
                }
            case .iceRestartDue:
                guard !connected else { continue }
                if signaling == nil {
                    endReason = "disconnected without signaling"
                    break loop
                }
                pc.restartIce()
                do { try await sendOffer(pc, sid: sid, iceRestart: true) } catch {
                    endReason = "ice restart failed: \(error)"
                    break loop
                }
                restartTask = Task {
                    // Give the restart 15 s before a full reconnect.
                    try? await Task.sleep(for: .seconds(15))
                    if !Task.isCancelled { sink.yield(.connectDeadline) }
                }
            case .connectDeadline:
                if !connected {
                    endReason = everConnected ? "ice restart timed out" : "connect timed out"
                    break loop
                }
            case .refreshPath, .peer(.selectedPairChanged):
                guard connected else { continue }
                let info = await pc.selectedPath()
                pathInfo.withLock { $0 = info }
                if let info { broadcaster.send(.connected(info.path)) }
            case .peer(.dataChannel):
                continue
            }
        }

        // Teardown.
        if signaling != nil, !endReason.hasPrefix("bye") { await sendSignal(.bye(sid: sid)) }
        for task in helpers { task.cancel() }
        restartTask?.cancel()
        refreshTask?.cancel()
        signalingRetry?.cancel()
        if self.session === session { self.session = nil }
        if connectedGate.isOpen { connectedGate = AsyncGate() }
        session.closeChannels()
        control?.close()
        pc.close()
        proxy.finish()
        signaling?.close()
        signaling = nil
        pathInfo.withLock { $0 = nil }
        return .ended(wasConnected: everConnected, reason: endReason)
    }
}
