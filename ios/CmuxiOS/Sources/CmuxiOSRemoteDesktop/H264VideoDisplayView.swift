import AVFoundation
import CmuxBrowserStream
import CoreMedia
import UIKit

/// Hardware-decoded H.264 on an `AVSampleBufferDisplayLayer` with
/// display-immediately samples: newest frame on the next refresh, no
/// playout queue (c2-browser-stream.md 8). Shared candidate with C2's
/// browser screen. The layer is placed at `videoRect` so a frame encoded
/// for one view keeps its place while the lens moves.
@MainActor
final class H264VideoDisplayView: UIView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        displayLayer.videoGravity = .resize
        layer.addSublayer(displayLayer)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Where the current frame's view lands, in this view's coordinates.
    var videoRect: CGRect = .zero {
        didSet {
            guard videoRect != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.frame = videoRect
            CATransaction.commit()
        }
    }

    /// Decodes and shows one Annex-B access unit. False when it could not
    /// be shown (no parameter sets yet, or the decoder needs a keyframe);
    /// the caller then asks the Mac for recovery.
    func enqueue(_ accessUnit: Data, isKeyframe: Bool, captureMicros: UInt64) -> Bool {
        let unit = H264AccessUnit(annexB: accessUnit)
        if let sps = unit.sps, let pps = unit.pps, let made = Self.format(sps: sps, pps: pps) {
            format = made
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
            return false
        }
        if renderer.requiresFlushToResumeDecoding {
            guard isKeyframe else { return false }
            renderer.flush()
        }
        guard let format, let sample = Self.sample(unit.lengthPrefixedSlices, format: format, micros: captureMicros) else {
            return false
        }
        renderer.enqueue(sample)
        return renderer.status != .failed
    }

    func reset() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        format = nil
    }

    private static func format(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        return status == noErr ? description : nil
    }

    private static func sample(_ slices: Data, format: CMVideoFormatDescription, micros: UInt64) -> CMSampleBuffer? {
        guard !slices.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: slices.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: slices.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = slices.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: slices.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = slices.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(micros), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
