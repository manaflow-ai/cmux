public import Foundation

/// A terminal the user can open from the phone: owned by the session host on
/// one machine (Mac, mini, Cloud VM, server).
public struct TerminalRef: Hashable, Sendable, Identifiable {
    public var host: String
    public var terminal: String
    public var title: String
    public var hostName: String

    public init(host: String, terminal: String, title: String, hostName: String) {
        self.host = host
        self.terminal = terminal
        self.title = title
        self.hostName = hostName
    }

    public var id: String { host + "/" + terminal }
}

/// How the bytes reach the phone; shown as a badge (spec sync-and-transport 6.5).
public enum TerminalPath: String, Hashable, Sendable {
    case directLAN, directWAN, relayed, durableObjectRelay, viaCloudRegion
}

/// Events of one attached terminal channel (`terminal_bytes`: snapshot, then live bytes).
public enum TerminalChannelEvent: Sendable {
    case snapshot(Data, cols: Int, rows: Int)
    case bytes(Data)
    case resized(cols: Int, rows: Int)
    case path(TerminalPath, rttMilliseconds: Double?)
    case kicked(byDisplayName: String)
    case closed(reason: String)
}

/// The transport seam (lane 12). The phone attaches, reports its presence
/// (visible viewport for the canonical grid), and sends input as ordered,
/// attributed runtime commands that never queue offline.
public protocol TerminalSessionSource: Sendable {
    func terminals() async throws -> [TerminalRef]
    func attach(_ terminal: TerminalRef) async throws -> AsyncStream<TerminalChannelEvent>
    func setPresence(_ terminal: TerminalRef, visible: Bool, cols: Int, rows: Int) async
    func send(_ input: Data, to terminal: TerminalRef) async throws
    func detach(_ terminal: TerminalRef) async
}

/// The rendering seam (lane 13, ghostty-next). Manual I/O: the renderer never
/// owns a PTY; the app feeds it bytes from the channel and forwards its
/// encoded input to the source.
@MainActor
public protocol TerminalRenderer: AnyObject {
    func feed(_ bytes: Data)
    func reset(snapshot: Data, cols: Int, rows: Int)
    /// The grid that fits the current view at the current font.
    var fittingGrid: (cols: Int, rows: Int) { get }
    /// Bytes to send when the user types, pastes or uses a key bar key.
    var onInput: ((Data) -> Void)? { get set }
}
