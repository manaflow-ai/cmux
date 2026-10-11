import CoreMedia
import CoreVideo
import Foundation

/// One received and decoded VIDEO frame.
struct FrameRecord {
    let tRecvNs: UInt64
    let bytes: Int
    let keyframe: Bool
    let decodeMs: Double
    let markerReadMs: Double
    let header: VideoHeader
    let marker: MarkerRead?
}

/// One completed glass-to-glass sample.
struct SampleRecord {
    let inputSeq: UInt32
    let t0Ns: UInt64
    let tRecvNs: UInt64
    let tDecodedNs: UInt64
    let decodeMs: Double
    let header: VideoHeader
    let frameBytes: Int
}

struct PongRecord {
    let tSendNs: UInt64
    let tRecvNs: UInt64
    let tHostNs: UInt64
    let underLoad: Bool
    var rttMs: Double { ms(tSendNs, tRecvNs) }
}

/// The receive side: one reader thread reads, decodes, reads the marker and completes samples.
/// The sampler thread arms a pending sample and waits on `sampleDone`.
final class Session: @unchecked Sendable {
    let sock: StreamSocket
    let pixelFormat: OSType
    private let lock = NSLock()

    // Guarded by lock.
    private(set) var helloAck: [String: Any]?
    private(set) var frames: [FrameRecord] = []
    private(set) var samples: [SampleRecord] = []
    private(set) var pongs: [PongRecord] = []
    private(set) var hostStats: [(UInt64, [String: Any])] = []
    private(set) var lastMarker: UInt16?
    private(set) var guardFailures = 0
    private(set) var decodeErrors = 0
    private(set) var lateMatches = 0
    private(set) var keyframeRequests = 0
    private(set) var byeReason: String?
    private(set) var readerError: String?
    private var closing = false
    private(set) var decoderHardware: Bool?
    private(set) var decoderRequireHonored: Bool?
    private var pending: (expected: UInt16, seq: UInt32, t0: UInt64)?
    private var lastLost: (expected: UInt16, seq: UInt32)?
    private var pendingPings: [UInt64: Bool] = [:]
    private var lastKeyframeReqNs: UInt64 = 0

    let ackReady = DispatchSemaphore(value: 0)
    let sampleDone = DispatchSemaphore(value: 0)
    let pongReady = DispatchSemaphore(value: 0)
    let firstMarker = DispatchSemaphore(value: 0)
    let readerExited = DispatchSemaphore(value: 0)

    private var decoder: VideoDecoder?
    private var sps: [UInt8] = []
    private var pps: [UInt8] = []
    private var sawFirstMarker = false

    init(sock: StreamSocket, pixelFormat: OSType) {
        self.sock = sock
        self.pixelFormat = pixelFormat
    }

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: sampler side

    /// Marks the end of the run so the reader does not report the expected EOF as an error.
    func markClosing() { withLock { closing = true } }

    func arm(expected: UInt16, seq: UInt32, t0: UInt64) {
        withLock { pending = (expected, seq, t0) }
    }

    /// Clears an unmatched sample after the 1000 ms timeout. Returns false if it matched meanwhile.
    func disarmIfPending(seq: UInt32) -> Bool {
        withLock {
            guard let p = pending, p.seq == seq else { return false }
            pending = nil
            lastLost = (p.expected, p.seq)
            return true
        }
    }

    func sendPing(underLoad: Bool) throws {
        let t = nowNs()
        withLock { pendingPings[t] = underLoad }
        var p: [UInt8] = []
        p.appendLE(t)
        try sock.writeAll(frame(.ping, p))
    }

    // MARK: reader side

    func runReader() {
        defer {
            sampleDone.signal(); ackReady.signal(); pongReady.signal(); firstMarker.signal()
            readerExited.signal()
        }
        do {
            while true {
                let m = try readMessage(sock)
                guard let type = MsgType(rawValue: m.type) else { continue }
                switch type {
                case .helloAck:
                    withLock { helloAck = jsonObject(m.payload) ?? ["raw": String(decoding: m.payload, as: UTF8.self)] }
                    ackReady.signal()
                case .video: handleVideo(m)
                case .pong: handlePong(m)
                case .hostStats:
                    if let o = jsonObject(m.payload) { withLock { hostStats.append((m.tRecvNs, o)) } }
                case .bye:
                    withLock { byeReason = String(decoding: m.payload, as: UTF8.self) }
                    return
                default: continue
                }
            }
        } catch {
            withLock { if !closing { readerError = "\(error)" } }
        }
    }

    private func handlePong(_ m: Message) {
        var r = LEReader(m.payload)
        guard let tc = r.u64(), let th = r.u64() else { return }
        let matched: Bool = withLock {
            guard let underLoad = pendingPings.removeValue(forKey: tc) else { return false }
            pongs.append(PongRecord(tSendNs: tc, tRecvNs: m.tRecvNs, tHostNs: th, underLoad: underLoad))
            return !underLoad
        }
        if matched { pongReady.signal() }
    }

    private func requestKeyframe() {
        let t = nowNs()
        let send: Bool = withLock {
            guard t - lastKeyframeReqNs > 500_000_000 else { return false }
            lastKeyframeReqNs = t
            keyframeRequests += 1
            return true
        }
        if send { try? sock.writeAll(frame(.keyframeReq, [])) }
    }

    private func handleVideo(_ m: Message) {
        guard let hdr = VideoHeader(m.payload) else {
            withLock { decodeErrors += 1 }
            return
        }
        let au = H264.parse(m.payload, from: VideoHeader.size)
        if let s = au.sps, let p = au.pps, s != sps || p != pps || decoder == nil {
            if let fd = H264.formatDescription(sps: s, pps: p) {
                if let d = decoder, d.canAccept(fd) {
                    // Same session keeps going; only parameter sets changed.
                } else {
                    decoder = nil
                    do {
                        let d = try VideoDecoder(format: fd, pixelFormat: pixelFormat)
                        decoder = d
                        withLock { decoderHardware = d.hardware; decoderRequireHonored = d.requireHardwareHonored }
                    } catch {
                        withLock { readerError = "\(error)" }
                    }
                }
                sps = s
                pps = p
            }
        }
        guard let dec = decoder, let fmt = H264.formatDescription(sps: sps, pps: pps),
              let sb = H264.sampleBuffer(avcc: au.avcc, format: fmt) else {
            withLock { decodeErrors += 1 }
            requestKeyframe()
            return
        }
        let r = dec.decode(sb, readMarker: true)
        if r.status != noErr {
            withLock { decodeErrors += 1 }
            requestKeyframe()
            return
        }
        let rec = FrameRecord(
            tRecvNs: m.tRecvNs, bytes: m.payload.count - VideoHeader.size, keyframe: hdr.isKeyframe || au.hasIDR,
            decodeMs: ms(r.tSubmitNs, r.tOutputNs), markerReadMs: Double(r.markerReadNs) / 1e6, header: hdr, marker: r.marker)
        var signalFirst = false
        var signalDone = false
        withLock {
            frames.append(rec)
            guard let mk = r.marker else { return }
            guard mk.guardOK else { guardFailures += 1; return }
            lastMarker = mk.value
            if !sawFirstMarker { sawFirstMarker = true; signalFirst = true }
            if let p = pending, mk.value == p.expected, hdr.lastInputSeq == 0 || hdr.lastInputSeq >= p.seq {
                samples.append(SampleRecord(
                    inputSeq: p.seq, t0Ns: p.t0, tRecvNs: m.tRecvNs, tDecodedNs: r.tOutputNs,
                    decodeMs: rec.decodeMs, header: hdr, frameBytes: rec.bytes))
                pending = nil
                signalDone = true
            } else if let l = lastLost, mk.value == l.expected {
                lateMatches += 1
                lastLost = nil
            }
        }
        if signalFirst { firstMarker.signal() }
        if signalDone { sampleDone.signal() }
    }
}
