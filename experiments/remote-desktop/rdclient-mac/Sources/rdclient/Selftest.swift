import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Offline loop: draw -> VTCompressionSession -> (Annex-B round trip for H.264) -> VTDecompressionSession
/// -> marker read. No network, no screen capture.
func runSelftest(_ a: Args) throws {
    let width = try a.int("width", default: 1920)
    let height = try a.int("height", default: 1080)
    let frames = try a.int("frames", default: 600)
    let bitrate = try a.int("bitrate-kbps", default: 8000) * 1000
    let fps = 60
    let codecs = a.string("codecs", default: "h264,hevc,av1").split(separator: ",").map(String.init)
    let workloads = a.string("workloads", default: "marker,text,motion").split(separator: ",").map(String.init)
    let codecTypes: [String: CMVideoCodecType] = [
        "h264": kCMVideoCodecType_H264, "hevc": kCMVideoCodecType_HEVC, "av1": kCMVideoCodecType_AV1,
    ]
    let inventory = encoderInventory()
    var runs: [[String: Any]] = []
    let utcStart = utcNow()
    for codecName in codecs {
        guard let ct = codecTypes[codecName] else { throw UsageError.message("unknown codec \(codecName)") }
        if !inventory.contains(where: { ($0["codec"] as? String) == codecName }) {
            runs.append(["codec": codecName, "skipped": "no \(codecName) encoder in VTCopyVideoEncoderList on this machine"])
            log("\(codecName): no encoder, skipped")
            continue
        }
        for wl in workloads {
            let workload: SyntheticWorkload
            switch wl {
            case "marker": workload = FlatGrayWorkload()
            case "text": workload = ScrollingTextWorkload(width: width, height: height, frames: frames)
            case "motion": workload = MotionWorkload()
            default: throw UsageError.message("unknown workload \(wl)")
            }
            log("\(codecName) \(wl) \(width)x\(height) x\(frames)")
            do {
                runs.append(try selftestRun(codec: ct, codecName: codecName, workload: workload,
                                            width: width, height: height, frames: frames, bitrate: bitrate, fps: fps))
            } catch {
                runs.append(["codec": codecName, "workload": wl, "error": "\(error)"])
            }
        }
    }
    let report: [String: Any] = [
        "tool": "rdclient-mac selftest",
        "utc_start": utcStart, "utc_end": utcNow(),
        "machine": machineInfo(),
        "settings": [
            "width": width, "height": height, "frames": frames, "bitrate_bps": bitrate, "fps_timestamps": fps,
            "source_pixel_format": "420f (full-range NV12), IOSurface-backed, from the encoder's pool",
            "decode_output_pixel_format": "420f",
            "pipeline": "serial: one frame in flight; encode submit->output, then decode submit->output",
            "not_measured": "screen capture (ScreenCaptureKit), color conversion from BGRA, display present",
        ],
        "encoder_inventory": inventory,
        "runs": runs,
    ]
    try emitJSON(report, to: a.string("out"))
}

private func selftestRun(codec: CMVideoCodecType, codecName: String, workload: SyntheticWorkload,
                         width: Int, height: Int, frames: Int, bitrate: Int, fps: Int) throws -> [String: Any] {
    let enc = try VideoEncoder(codec: codec, width: width, height: height, bitrate: bitrate, fps: fps)
    let pool = try enc.pool()
    var decoder: VideoDecoder?
    var drawMs: [Double] = [], encMs: [Double] = [], decMs: [Double] = [], convMs: [Double] = []
    var sizes: [Double] = [], keySizes: [Double] = []
    var markerOK = 0, markerBad = 0, dropped = 0, encErrors = 0, decErrors = 0, keyframes = 0
    var decoderHW: Bool?
    var decoderRequire: Bool?
    let cpu0 = CPUTimes.now()
    for i in 0..<frames {
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut) == kCVReturnSuccess,
              let pb = pbOut else { encErrors += 1; continue }
        let d0 = nowNs()
        CVPixelBufferLockBaseAddress(pb, [])
        if let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let uvb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let y = yb.assumingMemoryBound(to: UInt8.self)
            let uv = uvb.assumingMemoryBound(to: UInt8.self)
            let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            workload.draw(frame: i, y: y, yStride: ys, uv: uv, uvStride: uvs, width: width, height: height)
            MarkerWriter.draw(counter: UInt16(truncatingIfNeeded: i), y: y, yStride: ys, uv: uv, uvStride: uvs, fullRange: true)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        drawMs.append(ms(d0, nowNs()))

        let r = enc.encode(pb, frameIndex: i, fps: fps)
        if r.dropped { dropped += 1; continue }
        guard r.status == noErr, let sb = r.sample else { encErrors += 1; continue }
        encMs.append(r.ms)
        let key = isKeyframe(sb)
        if key { keyframes += 1 }
        let size = Double(CMSampleBufferGetTotalSampleSize(sb))
        if key { keySizes.append(size) } else { sizes.append(size) }

        // H.264 goes through the same Annex-B parser the network client uses.
        var decodeSample: CMSampleBuffer? = sb
        var format = CMSampleBufferGetFormatDescription(sb)
        if codec == kCMVideoCodecType_H264 {
            let c0 = nowNs()
            decodeSample = nil
            if let annexB = H264.annexB(from: sb, keyframe: key) {
                let au = H264.parse(annexB, from: 0)
                if let s = au.sps, let p = au.pps { format = H264.formatDescription(sps: s, pps: p) }
                else if let d = decoder { format = d.format }
                if let f = format { decodeSample = H264.sampleBuffer(avcc: au.avcc, format: f) }
            }
            convMs.append(ms(c0, nowNs()))
        }
        guard let dsb = decodeSample, let fmt = format else { decErrors += 1; continue }
        if decoder == nil || !(decoder?.canAccept(fmt) ?? false) {
            let d = try VideoDecoder(format: fmt, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            decoder = d
            decoderHW = d.hardware
            decoderRequire = d.requireHardwareHonored
        }
        guard let dec = decoder else { continue }
        let dr = dec.decode(dsb, readMarker: true)
        if dr.status != noErr { decErrors += 1; continue }
        decMs.append(ms(dr.tSubmitNs, dr.tOutputNs))
        if let m = dr.marker, m.guardOK, m.value == UInt16(truncatingIfNeeded: i) { markerOK += 1 } else { markerBad += 1 }
    }
    let cpu = cpu0.delta(to: CPUTimes.now())
    let allSizes = sizes + keySizes
    let meanP = sizes.isEmpty ? 0 : sizes.reduce(0, +) / Double(sizes.count)
    return [
        "codec": codecName, "workload": workload.name,
        "encoder": [
            "hardware_at_create": enc.hardware, "hardware_after_encode": enc.queryHardware(),
            "require_hardware_honored": enc.requireHardwareHonored,
            "low_latency_rate_control": enc.lowLatencyRateControl, "property_status": enc.propertyStatus,
        ],
        "decoder": ["hardware": orNull(decoderHW), "require_hardware_honored": orNull(decoderRequire)],
        "frames": frames, "encoded": encMs.count, "decoded": decMs.count, "keyframes": keyframes,
        "dropped": dropped, "encode_errors": encErrors, "decode_errors": decErrors,
        "marker_ok": markerOK, "marker_bad": markerBad,
        "draw_ms": percentiles(drawMs),
        "encode_ms": percentiles(encMs),
        "annexb_roundtrip_ms": percentiles(convMs),
        "decode_ms": percentiles(decMs),
        "bytes_per_frame_p_frames": percentiles(sizes),
        "bytes_keyframes": percentiles(keySizes),
        "kbit_per_s_at_60fps_p_frames": round3(meanP * 8 * 60 / 1000),
        "bytes_total": Int(allSizes.reduce(0, +)),
        "process_cpu": cpu,
    ]
}
