import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum SimStreamVideoEncoderError: Error {
    case sessionCreationFailed(OSStatus)
    case encodeFailed(OSStatus)
    case frameDropped
    case missingSampleData
    case parameterSetExtractionFailed(OSStatus)
    case invalidated
}

public struct SimStreamEncodedFrame: Sendable {
    /// AVCC/HVCC length-prefixed NAL units, exactly as VideoToolbox emitted.
    public let data: Data
    public let isKeyframe: Bool
    /// Parameter sets from the frame's format description (populated on
    /// keyframes; empty otherwise since the description cannot change
    /// mid-stream without a reconfigure).
    public let parameterSets: [Data]
    public let nalUnitHeaderLength: UInt8
}

/// Real-time HEVC/H.264 encoder tuned for interactive streaming: no frame
/// reordering (zero algorithmic latency), low-latency rate control, and
/// keyframes only on demand (attach, geometry change, loss recovery).
///
/// An actor so encode, bitrate updates, and invalidation serialize without
/// blocking any cooperative thread; the encode itself suspends on a
/// continuation resumed by VideoToolbox's completion.
public actor SimStreamVideoEncoder {
    /// Owns invalidation in its deinit so the actor's nonisolated deinit
    /// never has to touch the non-Sendable VideoToolbox session directly.
    private final class VTSessionBox: @unchecked Sendable {
        let session: VTCompressionSession
        init(_ session: VTCompressionSession) { self.session = session }
        deinit { VTCompressionSessionInvalidate(session) }
    }

    private var box: VTSessionBox?
    private var session: VTCompressionSession? { box?.session }
    public let codec: SimStreamVideoCodec
    public let width: Int
    public let height: Int
    private var bitsPerSecond: Int

    public init(
        codec: SimStreamVideoCodec,
        width: Int,
        height: Int,
        bitsPerSecond: Int
    ) throws {
        self.codec = codec
        self.width = width
        self.height = height
        self.bitsPerSecond = bitsPerSecond

        let codecType: CMVideoCodecType =
            codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let encoderSpecification =
            [
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
            ] as CFDictionary
        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: codecType,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        if status != noErr || created == nil {
            // Low-latency rate control requires a hardware encoder; retry
            // without it so software fallbacks (older Intel HEVC) still work.
            status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(width),
                height: Int32(height),
                codecType: codecType,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &created
            )
        }
        guard status == noErr, let session = created else {
            throw SimStreamVideoEncoderError.sessionCreationFailed(status)
        }
        self.box = VTSessionBox(session)

        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: kCFBooleanTrue)
        // Keyframes are on-demand only: a long-lived stream never pays for a
        // scheduled keyframe it did not need.
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: 1_000_000 as CFNumber)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: 60 as CFNumber)
        if codec == .h264 {
            VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_H264_High_AutoLevel)
        }
        Self.applyBitrate(bitsPerSecond, to: session)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    public func invalidate() {
        box = nil
    }

    public func setBitrate(_ bitsPerSecond: Int) {
        guard let session, bitsPerSecond != self.bitsPerSecond else { return }
        self.bitsPerSecond = bitsPerSecond
        Self.applyBitrate(bitsPerSecond, to: session)
    }

    /// Encodes one frame. Real-time sessions with reordering disabled emit
    /// exactly one output per input, so this suspends until that output.
    public func encode(
        _ pixelBuffer: CVPixelBuffer,
        presentationMicroseconds: UInt64,
        forceKeyframe: Bool
    ) async throws -> SimStreamEncodedFrame {
        guard let session else {
            throw SimStreamVideoEncoderError.invalidated
        }
        let presentation = CMTime(
            value: CMTimeValue(presentationMicroseconds), timescale: 1_000_000)
        var frameProperties: CFDictionary?
        if forceKeyframe {
            frameProperties =
                [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
        }

        let output: EncodeOutput = try await withCheckedThrowingContinuation { continuation in
            let box = EncodeContinuationBox(continuation)
            let submitStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentation,
                duration: .invalid,
                frameProperties: frameProperties,
                infoFlagsOut: nil
            ) { status, flags, sampleBuffer in
                box.resume(status: status, flags: flags, sampleBuffer: sampleBuffer)
            }
            if submitStatus != noErr {
                box.resumeSubmitFailure(status: submitStatus)
            }
        }
        guard output.status == noErr else {
            throw SimStreamVideoEncoderError.encodeFailed(output.status)
        }
        guard !output.flags.contains(.frameDropped), let sampleBuffer = output.sampleBuffer
        else {
            throw SimStreamVideoEncoderError.frameDropped
        }
        return try Self.extract(from: sampleBuffer, codec: codec)
    }

    private static func applyBitrate(_ bitsPerSecond: Int, to session: VTCompressionSession) {
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AverageBitRate,
            value: bitsPerSecond as CFNumber)
        // Hard cap bursts at 1.5x the average over one second so a keyframe
        // cannot flood a constrained link.
        let bytesPerSecond = bitsPerSecond / 8 * 3 / 2
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_DataRateLimits,
            value: [bytesPerSecond as CFNumber, 1 as CFNumber] as CFArray)
    }

    private static func extract(
        from sampleBuffer: CMSampleBuffer,
        codec: SimStreamVideoCodec
    ) throws -> SimStreamEncodedFrame {
        let isKeyframe: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
            let first = attachments.first
        {
            isKeyframe = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        } else {
            isKeyframe = true
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw SimStreamVideoEncoderError.missingSampleData
        }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress else {
                throw SimStreamVideoEncoderError.missingSampleData
            }
            let copyStatus = CMBlockBufferCopyDataBytes(
                dataBuffer, atOffset: 0, dataLength: length, destination: base)
            guard copyStatus == kCMBlockBufferNoErr else {
                throw SimStreamVideoEncoderError.encodeFailed(copyStatus)
            }
        }

        var parameterSets: [Data] = []
        var nalUnitHeaderLength: UInt8 = 4
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            (parameterSets, nalUnitHeaderLength) = try Self.parameterSets(
                from: format, codec: codec)
        }
        return SimStreamEncodedFrame(
            data: data,
            isKeyframe: isKeyframe,
            parameterSets: parameterSets,
            nalUnitHeaderLength: nalUnitHeaderLength
        )
    }

    private static func parameterSets(
        from format: CMFormatDescription,
        codec: SimStreamVideoCodec
    ) throws -> ([Data], UInt8) {
        var count = 0
        var nalHeaderLength: Int32 = 4
        let probeStatus: OSStatus
        switch codec {
        case .hevc:
            probeStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalHeaderLength)
        case .h264:
            probeStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalHeaderLength)
        }
        guard probeStatus == noErr, count > 0 else {
            throw SimStreamVideoEncoderError.parameterSetExtractionFailed(probeStatus)
        }
        var sets: [Data] = []
        sets.reserveCapacity(count)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            switch codec {
            case .hevc:
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
            case .h264:
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let pointer else {
                throw SimStreamVideoEncoderError.parameterSetExtractionFailed(status)
            }
            sets.append(Data(bytes: pointer, count: size))
        }
        return (sets, UInt8(clamping: nalHeaderLength))
    }
}

/// Checked by hand: VideoToolbox transfers sole ownership of the emitted
/// sample buffer to the output handler, and exactly one continuation consumer
/// reads it.
private struct EncodeOutput: @unchecked Sendable {
    let status: OSStatus
    let flags: VTEncodeInfoFlags
    let sampleBuffer: CMSampleBuffer?
}

/// VideoToolbox calls its output handler exactly once per accepted frame, on
/// its own queue; when submission itself fails no handler runs. This box
/// makes those two exclusive paths race-safe for one continuation.
private final class EncodeContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<EncodeOutput, any Error>?

    init(_ continuation: CheckedContinuation<EncodeOutput, any Error>) {
        self.continuation = continuation
    }

    func resume(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        take()?.resume(
            returning: EncodeOutput(status: status, flags: flags, sampleBuffer: sampleBuffer))
    }

    func resumeSubmitFailure(status: OSStatus) {
        take()?.resume(throwing: SimStreamVideoEncoderError.encodeFailed(status))
    }

    private func take() -> CheckedContinuation<EncodeOutput, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }
}
