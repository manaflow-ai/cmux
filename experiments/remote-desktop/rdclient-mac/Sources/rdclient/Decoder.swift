import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Result of decoding one access unit.
struct DecodeResult {
    let status: OSStatus
    let tSubmitNs: UInt64
    let tOutputNs: UInt64
    let marker: MarkerRead?
    let markerReadNs: UInt64
}

enum DecoderError: Error, CustomStringConvertible {
    case create(OSStatus)
    var description: String {
        switch self {
        case .create(let s): return "VTDecompressionSessionCreate failed: \(s)"
        }
    }
}

/// VTDecompressionSession in synchronous mode: decodeFrame returns after the output handler ran,
/// so submit->output is the full decode latency including the GPU/media-engine round trip.
final class VideoDecoder {
    let session: VTDecompressionSession
    let format: CMVideoFormatDescription
    let pixelFormat: OSType
    let hardware: Bool
    let requireHardwareHonored: Bool

    init(format: CMVideoFormatDescription, pixelFormat: OSType) throws {
        self.format = format
        self.pixelFormat = pixelFormat
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: Int(dims.width),
            kCVPixelBufferHeightKey: Int(dims.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        var created: VTDecompressionSession?
        var requireHonored = true
        let hwSpec: [CFString: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
        var st = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: hwSpec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &created)
        if st != noErr {
            // Hardware refused (e.g. no GPU session): fall back and report it.
            requireHonored = false
            let swSpec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
            st = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: format,
                decoderSpecification: swSpec as CFDictionary,
                imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                decompressionSessionOut: &created)
        }
        guard st == noErr, let created else { throw DecoderError.create(st) }
        session = created
        requireHardwareHonored = requireHonored
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var hw: CFTypeRef?
        let hst = withUnsafeMutablePointer(to: &hw) {
            VTSessionCopyProperty(
                created, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                allocator: kCFAllocatorDefault, valueOut: $0)
        }
        hardware = hst == noErr && (hw as? Bool ?? false)
    }

    deinit {
        VTDecompressionSessionInvalidate(session)
    }

    func canAccept(_ fd: CMVideoFormatDescription) -> Bool {
        VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: fd)
    }

    /// Decodes one sample synchronously and reads the marker from the output Y plane.
    func decode(_ sb: CMSampleBuffer, readMarker: Bool) -> DecodeResult {
        final class Box: @unchecked Sendable {
            var status: OSStatus = -1
            var tOut: UInt64 = 0
            var marker: MarkerRead?
            var markerNs: UInt64 = 0
        }
        let box = Box()
        let t0 = nowNs()
        var flagsOut = VTDecodeInfoFlags()
        let st = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sb, flags: [._1xRealTimePlayback], infoFlagsOut: &flagsOut
        ) { status, _, image, _, _ in
            box.tOut = nowNs()
            box.status = status
            if readMarker, status == noErr, let image {
                let m0 = nowNs()
                box.marker = MarkerReader.read(image)
                box.markerNs = nowNs() - m0
            }
        }
        if st != noErr { box.status = st }
        if box.tOut == 0 {
            // Output did not arrive inside the synchronous call; flush so it does.
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            if box.tOut == 0 { box.tOut = nowNs() }
        }
        return DecodeResult(status: box.status, tSubmitNs: t0, tOutputNs: box.tOut, marker: box.marker, markerReadNs: box.markerNs)
    }
}

func fourCC(_ s: String) -> OSType {
    s.utf8.reduce(0) { ($0 << 8) | OSType($1) }
}
