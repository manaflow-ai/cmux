import CoreMedia
import CoreVideo
import Foundation

/// Loopback test host: serves rdproto/0 on 127.0.0.1 with the `marker` workload in `damage`
/// mode, encoding with VideoToolbox. It exists to check the client end to end without the
/// Linux host; its numbers describe a macOS host encode path, not the Linux prototype.
func runFakeHost(_ a: Args) throws {
    let port = UInt16(try a.int("port", default: 7400))
    log("fakehost listening on 127.0.0.1:\(port)")
    let sock = try StreamSocket.acceptOne(port: port)
    let hello = try readMessage(sock)
    guard hello.type == MsgType.hello.rawValue, let h = jsonObject(hello.payload) else {
        throw UsageError.message("expected HELLO")
    }
    let width = (h["width"] as? Int) ?? 1920
    let height = (h["height"] as? Int) ?? 1080
    let enc = try VideoEncoder(codec: kCMVideoCodecType_H264, width: width, height: height,
                               bitrate: ((h["bitrate_kbps"] as? Int) ?? 8000) * 1000, fps: 60)
    let pool = try enc.pool()
    let machine = machineInfo()
    let ack: [String: Any] = [
        "width": width, "height": height, "encoder": "VideoToolbox H.264 low-latency (loopback test host)",
        "capture": "damage", "host": machine["host"] ?? "", "cpu": machine["chip"] ?? "", "cores": machine["cores"] ?? 0,
    ]
    try sock.writeAll(frame(.helloAck, Array(try JSONSerialization.data(withJSONObject: ack))))

    var counter: UInt16 = 0
    var frameSeq: UInt64 = 0
    var lastInput: UInt32 = 0
    func sendFrame(tDamage: UInt64, forceKey: Bool) throws {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let pb = out else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let uvb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let y = yb.assumingMemoryBound(to: UInt8.self), uv = uvb.assumingMemoryBound(to: UInt8.self)
            let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            FlatGrayWorkload().draw(frame: 0, y: y, yStride: ys, uv: uv, uvStride: uvs, width: width, height: height)
            MarkerWriter.draw(counter: counter, y: y, yStride: ys, uv: uv, uvStride: uvs, fullRange: true)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        let tCapture = nowNs()
        let r = enc.encode(pb, frameIndex: Int(frameSeq), fps: 60, forceKeyframe: forceKey)
        let tEncoded = nowNs()
        guard r.status == noErr, let sb = r.sample else { return }
        let key = isKeyframe(sb)
        guard let annexB = H264.annexB(from: sb, keyframe: key) else { return }
        var p: [UInt8] = []
        p.reserveCapacity(VideoHeader.size + annexB.count)
        p.appendLE(frameSeq); p.appendLE(tDamage); p.appendLE(tCapture); p.appendLE(tEncoded)
        p.appendLE(lastInput); p.appendLE(UInt32(key ? 1 : 0)); p.appendLE(UInt32(width)); p.appendLE(UInt32(height))
        p.append(contentsOf: annexB)
        try sock.writeAll(frame(.video, p))
        frameSeq += 1
    }
    try sendFrame(tDamage: nowNs(), forceKey: true)
    while true {
        let m = try readMessage(sock)
        guard let type = MsgType(rawValue: m.type) else { continue }
        switch type {
        case .input:
            var r = LEReader(m.payload)
            guard let seq = r.u32(), let kind = r.u32() else { continue }
            lastInput = seq
            if kind == 1 { counter &+= 1; try sendFrame(tDamage: m.tRecvNs, forceKey: false) }
        case .keyframeReq: try sendFrame(tDamage: nowNs(), forceKey: true)
        case .ping:
            var r = LEReader(m.payload)
            guard let tc = r.u64() else { continue }
            var p: [UInt8] = []
            p.appendLE(tc); p.appendLE(nowNs())
            try sock.writeAll(frame(.pong, p))
        case .bye: return
        default: continue
        }
    }
}
