#if canImport(WebRTC)
import CNCore
import CNTransport
import Foundation
import os
@preconcurrency import WebRTC

let webRTCLog = Logger(subsystem: "dev.cmux.next", category: "webrtc")

/// Process-wide WebRTC factory. Creating `RTCPeerConnectionFactory` is
/// expensive and SSL must be initialized once, so it lives for the process.
final class WebRTCRuntime: @unchecked Sendable {
    static let shared = WebRTCRuntime()

    let factory: RTCPeerConnectionFactory

    private init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory()
    }
}

/// Connects to a host over WebRTC data channels (PROTOCOL §1, §5). The phone
/// is the offerer; lanes are negotiated channels 0/1/2 (`ctl`/`int`/`blk`),
/// ordered and reliable; ICE is trickled through `SignalingClient`.
public final class WebRTCConnector: Connector {
    public struct Options: Sendable, Hashable {
        /// Force TURN relay candidates only (`iceTransportPolicy = relay`).
        public var relayOnly: Bool
        public var connectTimeout: Duration
        /// How long ICE may stay `disconnected` before the link is failed.
        /// libwebrtc reports `disconnected` after a couple of seconds without
        /// check responses and usually recovers; relayed paths (two TURN hops)
        /// and a busy device stall for several seconds without being dead.
        /// libwebrtc itself moves to `failed` after about 30 s.
        public var disconnectGrace: Duration

        public init(relayOnly: Bool = false, connectTimeout: Duration = .seconds(20), disconnectGrace: Duration = .seconds(20)) {
            self.relayOnly = relayOnly; self.connectTimeout = connectTimeout; self.disconnectGrace = disconnectGrace
        }
    }

    public let signaling: SignalingClient
    public let options: Options
    private let fetchICE: @Sendable () async throws -> ICEConfiguration

    /// - Parameter fetchICE: returns `GET /v1/ice` (for example
    ///   `{ try await backend.iceConfiguration() }`).
    public init(signaling: SignalingClient, options: Options = Options(), fetchICE: @escaping @Sendable () async throws -> ICEConfiguration) {
        self.signaling = signaling
        self.options = options
        self.fetchICE = fetchICE
    }

    public func connect(hostId: String) async throws -> any LinkTransport {
        async let ice = fetchICE()
        try await signaling.waitUntilConnected()
        let transport = try WebRTCLinkTransport(hostId: hostId, ice: try await ice, signaling: signaling, options: options)
        do {
            try await transport.open()
        } catch {
            transport.close(reason: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            throw error
        }
        return transport
    }
}

/// One peer connection with three negotiated data channels.
final class WebRTCLinkTransport: NSObject, LinkTransport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    let hostId: String
    let sessionId: String

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let signaling: SignalingClient
    private let options: WebRTCConnector.Options
    private let lock = NSLock()
    private var peerConnection: RTCPeerConnection!
    private var channels: [Lane: RTCDataChannel] = [:]
    private var openWaiter: CheckedContinuation<Void, any Error>?
    private var isOpen = false
    private var isClosed = false
    private var remoteDescriptionSet = false
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var signalTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?

    init(hostId: String, ice: ICEConfiguration, signaling: SignalingClient, options: WebRTCConnector.Options) throws {
        self.hostId = hostId
        self.sessionId = "s_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        self.signaling = signaling
        self.options = options
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        super.init()

        let config = RTCConfiguration()
        config.iceServers = ice.iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.iceTransportPolicy = options.relayOnly ? .relay : .all
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = WebRTCRuntime.shared.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw TransportError.connectFailed("Could not create a peer connection")
        }
        peerConnection = pc
        for lane in Lane.allCases {
            let c = RTCDataChannelConfiguration()
            c.isNegotiated = true
            c.channelId = Int32(lane.rawValue)
            c.isOrdered = true
            guard let channel = pc.dataChannel(forLabel: lane.label, configuration: c) else {
                throw TransportError.connectFailed("Could not create the \(lane.label) channel")
            }
            channel.delegate = self
            channels[lane] = channel
        }
    }

    // MARK: Open

    func open() async throws {
        let incoming = signaling.messages()
        let sessionId = self.sessionId
        let task = Task { [weak self] in
            for await message in incoming where message.sessionId == sessionId {
                self?.handleSignal(message)
            }
        }
        let closedAlready = lock.withLock { () -> Bool in
            if !isClosed { signalTask = task }
            return isClosed
        }
        if closedAlready { task.cancel(); throw TransportError.closed }

        let sdp: String = try await withCheckedThrowingContinuation { c in
            peerConnection.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] description, error in
                guard let self, let description else {
                    c.resume(throwing: error ?? TransportError.connectFailed("Could not create an offer"))
                    return
                }
                self.peerConnection.setLocalDescription(description) { error in
                    if let error { c.resume(throwing: error) } else { c.resume(returning: description.sdp) }
                }
            }
        }
        try await signaling.send(Self.offerMessage(hostId: hostId, sessionId: sessionId, sdp: sdp, relayOnly: options.relayOnly))

        let timeout = options.connectTimeout
        let timer = Task { [weak self] in
            do { try await ContinuousClock().sleep(for: timeout) } catch { return }
            self?.failOpen(TransportError.timedOut)
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if isOpen { lock.unlock(); c.resume(); return }
            if isClosed { lock.unlock(); c.resume(throwing: TransportError.closed); return }
            openWaiter = c
            lock.unlock()
        }
        let path = await pathInfo()
        if options.relayOnly, path.localCandidate != .relay {
            // libjuice can still form a direct path from peer-reflexive
            // candidates; a relay-only link must not open on one (PROTOCOL §5).
            let found = path.localCandidate?.rawValue ?? "unknown"
            close(reason: "Relay only: the selected path is \(found), not relay.")
            throw TransportError.connectFailed("Relay only: could not establish a TURN relay path (selected \(found)).")
        }
        continuation.yield(.pathChanged(path))
    }

    /// The offer frame. `policy:"relay"` (PROTOCOL §5) asks the host to use a
    /// relay-only ICE policy for this session too.
    static func offerMessage(hostId: String, sessionId: String, sdp: String, relayOnly: Bool) -> SignalMessage {
        guard relayOnly else { return .offer(to: hostId, from: nil, sessionId: sessionId, sdp: sdp) }
        return .unknown(type: "offer", raw: .object([
            "type": .string("offer"),
            "to": .string(hostId),
            "sessionId": .string(sessionId),
            "sdp": .string(sdp),
            "policy": .string("relay"),
        ]))
    }

    /// Whether an ICE candidate line is a `relay` candidate.
    static func isRelayCandidate(_ sdp: String) -> Bool {
        let fields = sdp.split(separator: " ")
        guard let typIndex = fields.firstIndex(of: "typ"), typIndex + 1 < fields.count else { return false }
        return fields[typIndex + 1] == "relay"
    }

    private func failOpen(_ error: any Error) {
        lock.lock()
        let waiter = openWaiter
        openWaiter = nil
        lock.unlock()
        waiter?.resume(throwing: error)
    }

    private func handleSignal(_ message: SignalMessage) {
        switch message {
        case .answer(_, _, _, let sdp):
            peerConnection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.failOpen(TransportError.connectFailed("Host answer rejected: \(error.localizedDescription)"))
                    return
                }
                self.lock.lock()
                self.remoteDescriptionSet = true
                let pending = self.pendingRemoteCandidates
                self.pendingRemoteCandidates.removeAll()
                self.lock.unlock()
                for candidate in pending { self.peerConnection.add(candidate) { _ in } }
            }
        case .candidate(_, _, _, let sdp, let mid, let index):
            if options.relayOnly, !Self.isRelayCandidate(sdp) { return }
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
            lock.lock()
            if remoteDescriptionSet {
                lock.unlock()
                peerConnection.add(candidate) { _ in }
            } else {
                pendingRemoteCandidates.append(candidate)
                lock.unlock()
            }
        case .bye:
            close(reason: "The host ended the session.")
        case .error(let code, let text, _):
            webRTCLog.error("link \(self.sessionId, privacy: .public) signaling error \(code, privacy: .public): \(text ?? "", privacy: .public)")
            let error = SignalingError.server(code: code, message: text)
            failOpen(error)
            close(reason: error.errorDescription)
        default:
            break
        }
    }

    // MARK: LinkTransport

    func send(_ chunks: [Data], on lane: Lane) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, let channel = channels[lane], channel.readyState == .open else { throw TransportError.closed }
        for chunk in chunks {
            guard channel.sendData(RTCDataBuffer(data: chunk, isBinary: true)) else {
                throw TransportError.sendFailed("\(lane.label) channel rejected data")
            }
        }
    }

    func close() {
        close(reason: nil)
    }

    func close(reason: String?) {
        lock.lock()
        if isClosed { lock.unlock(); return }
        isClosed = true
        let waiter = openWaiter
        openWaiter = nil
        let channels = Array(self.channels.values)
        let signalTask = self.signalTask, graceTask = self.graceTask
        self.signalTask = nil
        self.graceTask = nil
        lock.unlock()

        webRTCLog.notice("link \(self.sessionId, privacy: .public) closed: \(reason ?? "local close", privacy: .public)")
        waiter?.resume(throwing: TransportError.connectFailed(reason ?? "Connection closed"))
        signalTask?.cancel()
        graceTask?.cancel()
        for c in channels { c.close() }
        peerConnection.close()
        continuation.yield(.closed(reason: reason))
        continuation.finish()
        let signaling = self.signaling, hostId = self.hostId, sessionId = self.sessionId
        Task { try? await signaling.send(.bye(to: hostId, from: nil, sessionId: sessionId)) }
    }

    func pathInfo() async -> PathInfo {
        let report: RTCStatisticsReport = await withCheckedContinuation { c in
            peerConnection.statistics { c.resume(returning: $0) }
        }
        let info = Self.pathInfo(from: report)
        let pairs = report.statistics.values.filter { $0.type == "candidate-pair" || $0.type == "transport" }
            .map { "\($0.type) \($0.id) \($0.values.filter { ["state", "nominated", "selectedCandidatePairId", "localCandidateId", "remoteCandidateId", "bytesReceived"].contains($0.key) })" }
        webRTCLog.debug("path stats \(self.sessionId, privacy: .public): \(pairs.joined(separator: " | "), privacy: .public)")
        let candidates = report.statistics.values.filter { $0.type == "local-candidate" || $0.type == "remote-candidate" }
            .map { "\($0.id)=\(String(describing: $0.values["candidateType"]))" }
        webRTCLog.debug("path candidates \(self.sessionId, privacy: .public): \(candidates.joined(separator: " "), privacy: .public)")
        return info
    }

    static func pathInfo(from report: RTCStatisticsReport) -> PathInfo {
        let stats = report.statistics
        // The transport's selected pair is libwebrtc's own answer. Without
        // it, use the nominated succeeded pair carrying the most traffic
        // (several pairs can be nominated over a link's life).
        var pairId = stats.values.first { $0.type == "transport" && $0.values["selectedCandidatePairId"] != nil }?
            .values["selectedCandidatePairId"] as? String
        if pairId == nil {
            func bytes(_ s: RTCStatistics) -> Double { (s.values["bytesReceived"] as? NSNumber)?.doubleValue ?? 0 }
            pairId = stats.values.filter {
                $0.type == "candidate-pair" && ($0.values["state"] as? String) == "succeeded" && (($0.values["nominated"] as? NSNumber)?.boolValue ?? false)
            }.max { bytes($0) < bytes($1) }?.id
        }
        var info = PathInfo(transport: "webrtc")
        guard let pairId, let pair = stats[pairId] else { return info }
        func type(_ key: String) -> CandidateType? {
            guard let id = pair.values[key] as? String, let raw = stats[id]?.values["candidateType"] as? String else { return nil }
            return CandidateType(rawValue: raw) ?? .unknown
        }
        info.localCandidate = type("localCandidateId")
        info.remoteCandidate = type("remoteCandidateId")
        if let rtt = (pair.values["currentRoundTripTime"] as? NSNumber)?.doubleValue { info.rttMs = rtt * 1000 }
        return info
    }

    private func checkAllOpen() {
        lock.lock()
        let allOpen = channels.count == Lane.allCases.count && channels.values.allSatisfy { $0.readyState == .open }
        guard allOpen, !isOpen else { lock.unlock(); return }
        isOpen = true
        let waiter = openWaiter
        openWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
}

extension WebRTCLinkTransport: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let message = SignalMessage.candidate(to: hostId, from: nil, sessionId: sessionId, candidate: candidate.sdp,
                                              sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)
        let signaling = self.signaling
        Task { try? await signaling.send(message) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        webRTCLog.notice("link \(self.sessionId, privacy: .public) ice \(newState.rawValue, privacy: .public)")
        switch newState {
        case .failed:
            failOpen(TransportError.connectFailed("Could not reach your Mac (ICE failed)."))
            close(reason: "The network path to your Mac failed.")
        case .closed:
            close(reason: nil)
        case .disconnected:
            let grace = options.disconnectGrace
            lock.lock()
            graceTask?.cancel()
            graceTask = isClosed ? nil : Task { [weak self] in
                do { try await ContinuousClock().sleep(for: grace) } catch { return }
                guard let self, self.peerConnection.iceConnectionState == .disconnected else { return }
                self.close(reason: "Lost the connection to your Mac.")
            }
            lock.unlock()
        case .connected, .completed:
            lock.lock()
            graceTask?.cancel()
            graceTask = nil
            let open = isOpen
            lock.unlock()
            if open {
                Task { [weak self] in
                    guard let self else { return }
                    self.continuation.yield(.pathChanged(await self.pathInfo()))
                }
            }
        default:
            break
        }
    }
}

extension WebRTCLinkTransport: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            checkAllOpen()
        case .closed, .closing:
            lock.lock()
            let wasOpen = isOpen
            lock.unlock()
            if wasOpen { close(reason: "The \(dataChannel.label) channel closed.") }
        default:
            break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let lane = Lane(rawValue: UInt8(truncatingIfNeeded: dataChannel.channelId)) else { return }
        continuation.yield(.chunk(lane, buffer.data))
    }
}
#endif
