import Foundation
import CmuxNativeWire
import Synchronization
@preconcurrency import WebRTC

// The Objective-C WebRTC objects marshal every call onto WebRTC's own
// signaling thread, so they are safe to share across tasks.
extension RTCPeerConnection: @retroactive @unchecked Sendable {}
extension RTCDataChannel: @retroactive @unchecked Sendable {}
extension RTCSessionDescription: @retroactive @unchecked Sendable {}
extension RTCIceCandidate: @retroactive @unchecked Sendable {}
extension RTCPeerConnectionFactory: @retroactive @unchecked Sendable {}
extension RTCStatisticsReport: @retroactive @unchecked Sendable {}

/// Process-wide WebRTC setup.
final class RTCEnvironment: Sendable {
    static let shared = RTCEnvironment()

    let factory: RTCPeerConnectionFactory

    private init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
    }

    func makePeerConnection(iceServers: [IceServerConfig], relayOnly: Bool, delegate: any RTCPeerConnectionDelegate) throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.iceServers = iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        config.iceTransportPolicy = relayOnly ? .relay : .all
        config.tcpCandidatePolicy = .enabled
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            throw LinkError(code: "webrtc", message: "could not create a peer connection")
        }
        return pc
    }

    static func channelConfiguration() -> RTCDataChannelConfiguration {
        let c = RTCDataChannelConfiguration()
        c.isOrdered = true
        return c
    }
}

/// Events from an `RTCPeerConnection`, delivered in order on one stream.
enum PeerEvent: Sendable {
    case candidate(IceCandidate)
    case connectionState(RTCPeerConnectionState)
    case dataChannel(RTCDataChannel)
    case selectedPairChanged
}

extension RTCPeerConnectionState: @retroactive @unchecked Sendable {}

/// Forwards `RTCPeerConnectionDelegate` callbacks into an `AsyncStream`.
final class PeerEventProxy: NSObject, RTCPeerConnectionDelegate, Sendable {
    let events: AsyncStream<PeerEvent>
    private let continuation: AsyncStream<PeerEvent>.Continuation
    /// Called synchronously on WebRTC's signaling thread when the remote opens
    /// a data channel, so its delegate is installed before any message.
    private let onDataChannel: Mutex<(@Sendable (RTCDataChannel) -> Void)?>

    init(onDataChannel: (@Sendable (RTCDataChannel) -> Void)? = nil) {
        (events, continuation) = AsyncStream<PeerEvent>.makeStream(bufferingPolicy: .unbounded)
        self.onDataChannel = Mutex(onDataChannel)
        super.init()
    }

    func finish() {
        onDataChannel.withLock { $0 = nil }
        continuation.finish()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        continuation.yield(.candidate(IceCandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid,
                                                   sdpMLineIndex: candidate.sdpMLineIndex)))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        if let handler = onDataChannel.withLock({ $0 }) { handler(dataChannel) }
        continuation.yield(.dataChannel(dataChannel))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        continuation.yield(.connectionState(newState))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChangeLocalCandidate local: RTCIceCandidate,
                        remoteCandidate remote: RTCIceCandidate, lastReceivedMs lastDataReceivedMs: Int32,
                        changeReason reason: String) {
        continuation.yield(.selectedPairChanged)
    }
}

// MARK: - Async wrappers

extension RTCPeerConnection {
    private static let noConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    func makeOffer(iceRestart: Bool = false) async throws -> RTCSessionDescription {
        let constraints = iceRestart
            ? RTCMediaConstraints(mandatoryConstraints: ["IceRestart": "true"], optionalConstraints: nil)
            : Self.noConstraints
        return try await withCheckedThrowingContinuation { c in
            self.offer(for: constraints) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? LinkError(code: "webrtc", message: "no offer")) }
            }
        }
    }

    func makeAnswer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { c in
            self.answer(for: Self.noConstraints) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? LinkError(code: "webrtc", message: "no answer")) }
            }
        }
    }

    func applyLocal(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            self.setLocalDescription(sdp) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    func applyRemote(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            self.setRemoteDescription(sdp) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    func addRemote(_ candidate: IceCandidate) async throws {
        let rtc = RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            self.add(rtc) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    func stats() async -> RTCStatisticsReport {
        await withCheckedContinuation { c in
            self.statistics { report in c.resume(returning: report) }
        }
    }

    /// Reads the selected candidate pair and classifies the path.
    func selectedPath() async -> LinkPathInfo? {
        let report = await stats()
        let all = report.statistics
        var pair: RTCStatistics?
        if let transport = all.values.first(where: { $0.type == "transport" }),
           let pairID = transport.values["selectedCandidatePairId"] as? String {
            pair = all[pairID]
        }
        if pair == nil {
            pair = all.values.first {
                $0.type == "candidate-pair" && ($0.values["state"] as? String) == "succeeded"
                    && (($0.values["nominated"] as? NSNumber)?.boolValue ?? false)
            }
        }
        guard let pair else { return nil }
        let local = (pair.values["localCandidateId"] as? String).flatMap { all[$0] }
        let remote = (pair.values["remoteCandidateId"] as? String).flatMap { all[$0] }
        let localType = local?.values["candidateType"] as? String
        let remoteType = remote?.values["candidateType"] as? String
        let rtt = (pair.values["currentRoundTripTime"] as? NSNumber)?.doubleValue
        let relayed = localType == "relay" || remoteType == "relay"
        return LinkPathInfo(
            path: relayed ? .relay : .direct,
            rtt: rtt.map { .milliseconds(Int($0 * 1000)) },
            localCandidateType: localType,
            remoteCandidateType: remoteType,
            relayProtocol: local?.values["relayProtocol"] as? String
        )
    }
}

// MARK: - Data channel

/// `LinkChannel` over an ordered, reliable `RTCDataChannel`.
final class WebRTCLinkChannel: NSObject, LinkChannel, RTCDataChannelDelegate, Sendable {
    static let highWaterMark: UInt64 = 4 << 20
    static let lowWaterMark: UInt64 = 1 << 20

    let label: String
    private let channel: RTCDataChannel
    private let lines = IncomingLines()
    private let framer = LineFramer()
    let opened = AsyncGate()
    private let drained = Mutex<[CheckedContinuation<Void, Never>]>([])
    private let sendLock = SendSerializer()
    private let onClose: Mutex<(@Sendable () -> Void)?>

    var incoming: AsyncStream<Data> { lines.stream }

    init(channel: RTCDataChannel, onClose: (@Sendable () -> Void)? = nil) {
        self.channel = channel
        self.label = channel.label
        self.onClose = Mutex(onClose)
        super.init()
        channel.delegate = self
        if channel.readyState == .open { opened.open() }
        if channel.readyState == .closed || channel.readyState == .closing { finish() }
    }

    func send(_ data: Data) async throws {
        try await opened.wait(timeout: .seconds(20), what: "channel open")
        let messages = framer.encode(line: data)
        try await sendLock.run {
            for message in messages {
                try await self.waitForBufferSpace()
                guard self.channel.readyState == .open else { throw LinkError.channelClosed }
                guard self.channel.sendData(RTCDataBuffer(data: message, isBinary: true)) else {
                    throw LinkError(code: "send_failed", message: "data channel refused a message")
                }
            }
        }
    }

    private func waitForBufferSpace() async throws {
        while channel.bufferedAmount > Self.highWaterMark {
            guard channel.readyState == .open else { throw LinkError.channelClosed }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                drained.withLock { $0.append(c) }
                // Re-check after registering, in case the buffer drained in between.
                if channel.bufferedAmount <= Self.lowWaterMark || channel.readyState != .open { resumeDrainWaiters() }
            }
        }
    }

    private func resumeDrainWaiters() {
        let waiters = drained.withLock { w in
            defer { w = [] }
            return w
        }
        for w in waiters { w.resume() }
    }

    func close() {
        channel.close()
        finish()
    }

    private func finish() {
        opened.fail(.channelClosed)
        lines.finish()
        resumeDrainWaiters()
        if let onClose = onClose.withLock({ c in defer { c = nil }; return c }) { onClose() }
    }

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open: opened.open()
        case .closing, .closed: finish()
        default: break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if !lines.deliver(message: buffer.data) { close() }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        if dataChannel.bufferedAmount <= Self.lowWaterMark { resumeDrainWaiters() }
    }
}

/// Serializes async sends so the fragments of one line are never interleaved
/// with another line's.
final class SendSerializer: Sendable {
    private let gate = Mutex<(busy: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let immediate = gate.withLock { g -> Bool in
                if !g.busy {
                    g.busy = true
                    return true
                }
                g.waiters.append(c)
                return false
            }
            if immediate { c.resume() }
        }
    }

    private func release() {
        let next = gate.withLock { g -> CheckedContinuation<Void, Never>? in
            if g.waiters.isEmpty {
                g.busy = false
                return nil
            }
            return g.waiters.removeFirst()
        }
        next?.resume()
    }
}
