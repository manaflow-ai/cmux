public import CmuxTerminalRenderCore

/// What a screen shows about a running session (badge, title).
public struct TerminalSessionStatus: Hashable, Sendable {
    public var path: TerminalPath?
    public var rttMilliseconds: Double?
    public var title: String?
    public var notice: Notice?

    public enum Notice: Hashable, Sendable {
        case kicked(byDisplayName: String)
        case closed(reason: String)
        /// The host's snapshot version differs: bytes are a replay.
        case byteReplay
    }

    public init(path: TerminalPath? = nil, rttMilliseconds: Double? = nil, title: String? = nil, notice: Notice? = nil) {
        self.path = path
        self.rttMilliseconds = rttMilliseconds
        self.title = title
        self.notice = notice
    }
}
