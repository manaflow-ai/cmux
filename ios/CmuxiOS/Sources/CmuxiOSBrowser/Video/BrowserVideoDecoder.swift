import CmuxBrowserStream
import CmuxiOSFeatureKit
import CoreMedia
import Foundation
import VideoToolbox

/// Decodes H.264 samples with VideoToolbox, off the main actor. A frame
/// that does not follow the last decoded one (lost or dropped reference)
/// is skipped and reported once, so the Mac sends a keyframe; nothing
/// corrupted is ever shown.
actor BrowserVideoDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var lastDecoded: UInt32?
    private var waitingForKeyframe = true
    private var reportedLoss = false
    private let output: @Sendable (BrowserDecodedFrame) -> Void
    private let needKeyframe: @Sendable () -> Void

    init(output: @escaping @Sendable (BrowserDecodedFrame) -> Void, needKeyframe: @escaping @Sendable () -> Void) {
        self.output = output
        self.needKeyframe = needKeyframe
    }

    func decode(_ sample: BrowserVideoSample) {
        guard sample.codec == BrowserVideoCodec.h264.rawValue else { return }
        let unit = H264AccessUnit(annexB: sample.accessUnit)
        if sample.isKeyframe {
            waitingForKeyframe = false
            reportedLoss = false
            if let sps = unit.sps, let pps = unit.pps, [sps, pps] != parameterSets {
                parameterSets = [sps, pps]
                makeSession(sps: sps, pps: pps)
            }
        } else if waitingForKeyframe || sample.refFrame != lastDecoded {
            lost()
            return
        }
        guard let session, let format, let buffer = Self.sampleBuffer(unit.lengthPrefixedSlices, format: format) else {
            lost()
            return
        }
        let output = output
        let result = BrowserDecodeResult()
        // No asynchronous-decode flag: the handler runs before this returns.
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer, flags: [], infoFlagsOut: nil) {
            status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                result.failed = true
                return
            }
            output(BrowserDecodedFrame(pixelBuffer: imageBuffer))
        }
        if status != noErr || result.failed {
            lost()
            return
        }
        lastDecoded = sample.frame
    }

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        parameterSets = []
        lastDecoded = nil
        waitingForKeyframe = true
        reportedLoss = false
    }

    private func lost() {
        waitingForKeyframe = true
        guard !reportedLoss else { return }
        reportedLoss = true
        needKeyframe()
    }

    private func makeSession(sps: Data, pps: Data) {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { return }
        format = description
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var created: VTDecompressionSession?
        let made = VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil,
                                                imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                                decompressionSessionOut: &created)
        guard made == noErr, let created else { return }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
    }

    private static func sampleBuffer(_ slices: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        guard !slices.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: slices.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: slices.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = slices.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: slices.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = slices.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
