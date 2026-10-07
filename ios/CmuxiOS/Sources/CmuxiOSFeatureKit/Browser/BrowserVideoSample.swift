public import Foundation

/// One encoded video frame to decode (H.264 Annex-B).
public struct BrowserVideoSample: Hashable, Sendable {
    public var frame: UInt32
    /// The frame this one predicts from; nil for a keyframe.
    public var refFrame: UInt32?
    public var isKeyframe: Bool
    /// `h264` or `hevc`.
    public var codec: String
    public var accessUnit: Data
    /// Host monotonic microseconds at capture (latency telemetry).
    public var captureMicros: UInt64

    public init(frame: UInt32, refFrame: UInt32?, isKeyframe: Bool, codec: String, accessUnit: Data, captureMicros: UInt64) {
        self.frame = frame
        self.refFrame = refFrame
        self.isKeyframe = isKeyframe
        self.codec = codec
        self.accessUnit = accessUnit
        self.captureMicros = captureMicros
    }
}
