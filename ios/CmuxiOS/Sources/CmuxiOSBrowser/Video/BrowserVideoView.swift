import AVFoundation
import CoreMedia
import UIKit

/// Shows decoded frames in an `AVSampleBufferDisplayLayer`, displayed
/// immediately (no timeline, newest frame wins). The layer's frame is the
/// page rect of the zoom lens, so zoom and pan are a layer move on the GPU.
@MainActor
final class BrowserVideoView: UIView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .secondarySystemBackground
        displayLayer.videoGravity = .resize
        layer.addSublayer(displayLayer)
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Places the page (in view coordinates).
    func setPageRect(_ rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = rect
        CATransaction.commit()
    }

    func show(_ frame: BrowserDecodedFrame) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame.pixelBuffer,
                                                           formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frame.pixelBuffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    func clear() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}
