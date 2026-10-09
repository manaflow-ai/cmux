public import CmuxTerminalRenderCore

/// What a screen shows about a running session (badge, title).
public struct TerminalSessionStatus: Hashable, Sendable {
    public var path: TerminalPath?
    public var rttMilliseconds: Double?
    public var title: String?
    public var notice: Notice?
    /// The source's connection (sources that report it), for the banner.
    public var connection: TerminalConnectionState?
    /// On-demand scrollback (sources that load it).
    public var history: TerminalHistoryState?
    /// A frame or bytes reached the surface since the session started.
    public var hasContent = false

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

    /// The badge and banner the screen shows (pure rules in RenderCore).
    public var chrome: TerminalChrome {
        let ended: Bool = switch notice {
        case .kicked, .closed: true
        case .byteReplay, nil: false
        }
        return TerminalChrome(path: path, rttMilliseconds: rttMilliseconds, connection: connection,
                              hasContent: hasContent, ended: ended)
    }
}
