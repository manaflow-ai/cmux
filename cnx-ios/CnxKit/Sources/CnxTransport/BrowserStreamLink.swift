import Foundation

/// One complete video frame of a streamed Mac browser tab.
public struct BrowserStreamFrame: Sendable {
    /// 0 = the page.
    public var stream: UInt16
    public var frame: UInt32
    public var keyframe: Bool
    /// H.264 Annex-B access unit (SPS and PPS before each IDR).
    public var accessUnit: Data
    /// Host capture time (host monotonic microseconds).
    public var captureMicros: UInt64
    /// When it was complete, on the stream's clock (``BrowserStreamConnection/nowMicros()``).
    public var receivedMicros: UInt64
    /// Capture to complete on the phone (host encode, network, reassembly);
    /// nil until the clock probes have an estimate.
    public var ageMicros: Int64?

    public init(stream: UInt16, frame: UInt32, keyframe: Bool, accessUnit: Data, captureMicros: UInt64,
                receivedMicros: UInt64, ageMicros: Int64?) {
        self.stream = stream
        self.frame = frame
        self.keyframe = keyframe
        self.accessUnit = accessUnit
        self.captureMicros = captureMicros
        self.receivedMicros = receivedMicros
        self.ageMicros = ageMicros
    }
}

/// Counters of one stream.
public struct BrowserStreamStats: Sendable, Equatable {
    public var frames: UInt64 = 0
    public var keyframes: UInt64 = 0
    public var bytes: UInt64 = 0
    public var framesLost: UInt64 = 0
    public var clockOffsetMicros: Int64?
    public var clockRTTMicros: UInt32?
    /// The newest frame came on the link's media lane (RTP), not the
    /// reliable `browser` channel (verify/browser-video-track.md).
    public var videoTrack = false
    /// What carried the newest frame: `track` (a WebRTC video track),
    /// `wg-rtp` (RTP inside the WireGuard tunnel) or `channel`.
    public var videoCarrier = "channel"
    /// Track frames skipped to a keyframe after an unrecoverable loss.
    public var trackFramesDropped: UInt64 = 0
    /// Track packets a NACK brought back.
    public var trackPacketsRecovered: UInt64 = 0

    public init() {}

    /// The carrier name for a frame that came on the media lane (or not)
    /// of a link over `transport`.
    public static func carrier(videoTrack: Bool, transport: TransportKind) -> String {
        guard videoTrack else { return "channel" }
        return transport == .wireGuard ? "wg-rtp" : "track"
    }
}

/// Where a stream delivers, on a library thread: hand off quickly.
public protocol BrowserStreamSink: AnyObject, Sendable {
    func browserFrame(_ frame: BrowserStreamFrame)
    /// An rb message from the host (`t` = `rb.page`, `rb.screen_applied`, ...)
    /// or an rd control message (`welcome`, `refused`, `ended`), as a JSON object.
    func browserMessage(_ json: Data)
    func browserClosed(code: String, reason: String)
}

/// An open streamed browser tab (cnx-ios/verify/browser-stream.md).
public protocol BrowserStreamConnection: AnyObject, Sendable {
    /// An rb control message (a JSON object whose `t` starts with `rb.`).
    func send(message: Data) throws
    /// An rb input event; `mustDeliver` repeats it until acknowledged.
    func send(input: Data, mustDeliver: Bool) throws
    func requestKeyframe()
    func noteDecode(micros: UInt32)
    func stats() -> BrowserStreamStats
    func nowMicros() -> UInt64
    func close()
}

/// A link that can stream a Mac browser tab (the `browser` service).
public protocol BrowserStreamOpening: Sendable {
    /// `tab`: the tab's key on the Mac (`s<surface>`); `url`: its first page.
    func openBrowser(tab: String, url: String?, sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection
}
