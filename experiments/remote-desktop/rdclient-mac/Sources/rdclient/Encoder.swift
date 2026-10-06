import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum EncoderError: Error, CustomStringConvertible {
    case create(OSStatus)
    case noPool
    var description: String {
        switch self {
        case .create(let s): return "VTCompressionSessionCreate failed: \(s)"
        case .noPool: return "encoder has no pixel buffer pool"
        }
    }
}

struct EncodeResult {
    let sample: CMSampleBuffer?
    let status: OSStatus
    let dropped: Bool
    let ms: Double
}

/// VTCompressionSession in low-latency real-time mode. One frame in flight: submit, wait for output.
final class VideoEncoder {
    let session: VTCompressionSession
    let codec: CMVideoCodecType
    let hardware: Bool
    let lowLatencyRateControl: Bool
    let requireHardwareHonored: Bool
    let propertyStatus: [String: Int]

    init(codec: CMVideoCodecType, width: Int, height: Int, bitrate: Int, fps: Int) throws {
        self.codec = codec
        let srcAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        // Try the strictest spec first, then relax; the report says which one held.
        let attempts: [(lowLatency: Bool, requireHW: Bool)] = [(true, true), (true, false), (false, true), (false, false)]
        var made: (VTCompressionSession, Bool, Bool)?
        var lastStatus: OSStatus = 0
        for a in attempts {
            var spec: [CFString: Any] = [:]
            if a.lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            if a.requireHW {
                spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
            } else {
                spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = true
            }
            var s: VTCompressionSession?
            lastStatus = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height), codecType: codec,
                encoderSpecification: spec as CFDictionary, imageBufferAttributes: srcAttrs as CFDictionary,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            if lastStatus == noErr, let s { made = (s, a.lowLatency, a.requireHW); break }
        }
        guard let (s, ll, req) = made else { throw EncoderError.create(lastStatus) }
        session = s
        lowLatencyRateControl = ll
        requireHardwareHonored = req

        var status: [String: Int] = [:]
        func setp(_ key: CFString, _ value: CFTypeRef, _ name: String) {
            status[name] = Int(VTSessionSetProperty(s, key: key, value: value))
        }
        setp(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime")
        setp(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering")
        setp(kVTCompressionPropertyKey_MaxKeyFrameInterval, 1_000_000 as CFNumber, "MaxKeyFrameInterval")
        setp(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 100_000 as CFNumber, "MaxKeyFrameIntervalDuration")
        setp(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber, "AverageBitRate")
        setp(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber, "ExpectedFrameRate")
        setp(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue, "PrioritizeEncodingSpeedOverQuality")
        if codec == kCMVideoCodecType_H264 {
            setp(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel, "ProfileLevel=H264_ConstrainedHigh_AutoLevel")
        } else if codec == kCMVideoCodecType_HEVC {
            setp(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel, "ProfileLevel=HEVC_Main_AutoLevel")
        }
        VTCompressionSessionPrepareToEncodeFrames(s)
        var hw: CFTypeRef?
        let st = withUnsafeMutablePointer(to: &hw) {
            VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                  allocator: kCFAllocatorDefault, valueOut: $0)
        }
        hardware = st == noErr && (hw as? Bool ?? false)
        propertyStatus = status
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// UsingHardwareAcceleratedVideoEncoder after frames were encoded, with the copy status
    /// (some modes answer only once the session has started, or not at all).
    func queryHardware() -> [String: Any] {
        var hw: CFTypeRef?
        let st = withUnsafeMutablePointer(to: &hw) {
            VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                  allocator: kCFAllocatorDefault, valueOut: $0)
        }
        return ["status": Int(st), "value": orNull(hw as? Bool)]
    }

    func pool() throws -> CVPixelBufferPool {
        guard let p = VTCompressionSessionGetPixelBufferPool(session) else { throw EncoderError.noPool }
        return p
    }

    func encode(_ pb: CVPixelBuffer, frameIndex: Int, fps: Int, forceKeyframe: Bool = false) -> EncodeResult {
        final class Box: @unchecked Sendable {
            var sample: CMSampleBuffer?
            var status: OSStatus = -1
            var dropped = false
            var tOut: UInt64 = 0
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
        let dur = CMTime(value: 1, timescale: CMTimeScale(fps))
        var props: CFDictionary?
        if frameIndex == 0 || forceKeyframe {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        let t0 = nowNs()
        let st = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb, presentationTimeStamp: pts, duration: dur,
            frameProperties: props, infoFlagsOut: nil
        ) { status, flags, sb in
            box.tOut = nowNs()
            box.status = status
            box.dropped = flags.contains(.frameDropped)
            box.sample = sb
            done.signal()
        }
        if st != noErr {
            return EncodeResult(sample: nil, status: st, dropped: false, ms: ms(t0, nowNs()))
        }
        if done.wait(timeout: .now() + 2) == .timedOut {
            return EncodeResult(sample: nil, status: -2, dropped: true, ms: ms(t0, nowNs()))
        }
        return EncodeResult(sample: box.sample, status: box.status, dropped: box.dropped, ms: ms(t0, box.tOut))
    }
}

func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
    guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
          let first = arr.first else { return true }
    return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
}

/// Encoders VideoToolbox reports on this machine, for H.264, HEVC and AV1.
func encoderInventory() -> [[String: Any]] {
    var list: CFArray?
    guard VTCopyVideoEncoderList(nil, &list) == noErr, let arr = list as? [[String: Any]] else { return [] }
    let wanted: [CMVideoCodecType: String] = [
        kCMVideoCodecType_H264: "h264", kCMVideoCodecType_HEVC: "hevc", kCMVideoCodecType_AV1: "av1",
    ]
    return arr.compactMap { e in
        guard let ct = (e[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value,
              let name = wanted[ct] else { return nil }
        return [
            "codec": name,
            "encoder_id": e[kVTVideoEncoderList_EncoderID as String] as? String ?? "",
            "name": e[kVTVideoEncoderList_EncoderName as String] as? String ?? "",
            "hardware": e[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool ?? false,
        ]
    }
}
