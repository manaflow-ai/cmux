import Foundation
public import CmuxNativeWire

/// How the active link reaches the host.
public enum LinkPath: Sendable, Equatable, CustomStringConvertible {
    /// Host and phone talk peer to peer (host, srflx or prflx candidates).
    case direct
    /// Traffic goes through a TURN relay.
    case relay
    /// Connected, path not determined yet.
    case unknown

    public var description: String {
        switch self {
        case .direct: "direct"
        case .relay: "relay"
        case .unknown: "unknown"
        }
    }
}

/// Detail about the selected path, refreshed while connected.
public struct LinkPathInfo: Sendable, Equatable {
    public var path: LinkPath
    /// Round-trip time of the selected candidate pair, if known.
    public var rtt: Duration?
    /// Local and remote candidate types (`host`, `srflx`, `prflx`, `relay`).
    public var localCandidateType: String?
    public var remoteCandidateType: String?
    /// Relay protocol (`udp`, `tcp`, `tls`) when relayed.
    public var relayProtocol: String?

    public init(path: LinkPath, rtt: Duration? = nil, localCandidateType: String? = nil,
                remoteCandidateType: String? = nil, relayProtocol: String? = nil) {
        self.path = path
        self.rtt = rtt
        self.localCandidateType = localCandidateType
        self.remoteCandidateType = remoteCandidateType
        self.relayProtocol = relayProtocol
    }
}

public enum LinkState: Sendable, Equatable, CustomStringConvertible {
    case connecting
    case connected(LinkPath)
    case reconnecting
    case failed(String)
    case closed

    public var description: String {
        switch self {
        case .connecting: "connecting"
        case .connected(let path): "connected(\(path))"
        case .reconnecting: "reconnecting"
        case .failed(let message): "failed(\(message))"
        case .closed: "closed"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .failed, .closed: true
        default: false
        }
    }
}

public struct LinkError: LocalizedError, Equatable, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code): \(message)" }

    /// User-facing copy (shown in error states; never the type name).
    public var errorDescription: String? {
        switch code {
        case "closed", "channel_closed": "The connection to your Mac closed."
        case "timeout": "Your Mac took too long to answer (\(message))."
        default: message.prefix(1).uppercased() + message.dropFirst()
        }
    }

    public static let closed = LinkError(code: "closed", message: "link is closed")
    public static let channelClosed = LinkError(code: "channel_closed", message: "channel is closed")
    public static func timeout(_ what: String) -> LinkError { .init(code: "timeout", message: "\(what) timed out") }
}

/// A connection from the phone to one host, carrying labeled channels.
public protocol HostLink: AnyObject, Sendable {
    /// Every access returns a new stream that first replays the current
    /// state, then follows changes. It finishes after `.closed` or a
    /// terminal `.failed`.
    var state: AsyncStream<LinkState> { get }
    /// Opens a reliable, ordered, message-framed channel. Waits for the link
    /// to connect. After a reconnect, channels opened earlier may have
    /// closed (their `incoming` finishes); reopen them on `.connected`.
    func openChannel(label: String) async throws -> any LinkChannel
    func close()
}

/// One labeled channel: newline-JSON lines in both directions.
public protocol LinkChannel: AnyObject, Sendable {
    var label: String { get }
    /// One complete line per element, without the trailing newline. A single
    /// consumer. Finishes when the channel closes.
    var incoming: AsyncStream<Data> { get }
    /// Sends one line (trailing newline optional), fragmenting above 16 KiB.
    func send(_ data: Data) async throws
    func close()
}

/// The far end of an accepted link, as the host sees it.
public struct LinkPeer: Sendable, Hashable, CustomStringConvertible {
    /// Signaling session id (or a loopback connection id).
    public var sid: String
    /// Worker user id the Durable Object stamped on the offer.
    public var userID: String?

    public init(sid: String, userID: String?) {
        self.sid = sid
        self.userID = userID
    }

    public var description: String { "peer(\(sid)\(userID.map { ", user \($0)" } ?? ""))" }
}

public enum HostAcceptorState: Sendable, Equatable {
    case stopped
    case connecting
    /// Registered with signaling and ready for offers.
    case listening
    case reconnecting(String)
    case failed(String)
}

/// Receives phones' channels on the host.
public protocol HostAcceptorDelegate: AnyObject, Sendable {
    func hostAcceptor(_ acceptor: any HostAcceptor, didOpen channel: any LinkChannel, from peer: LinkPeer)
    func hostAcceptor(_ acceptor: any HostAcceptor, peerDidConnect peer: LinkPeer, path: LinkPathInfo?)
    func hostAcceptor(_ acceptor: any HostAcceptor, peerDidDisconnect peer: LinkPeer)
    /// The peer sent nothing on any channel for `idle` and is being dropped;
    /// `peerDidDisconnect` follows.
    func hostAcceptor(_ acceptor: any HostAcceptor, peerDidTimeOut peer: LinkPeer, idle: Duration)
    func hostAcceptor(_ acceptor: any HostAcceptor, didChange state: HostAcceptorState)
    /// The Worker relayed a notification response from `userID`'s phone.
    func hostAcceptor(_ acceptor: any HostAcceptor, didReceiveAction action: JSONValue, from userID: String?)
}

extension HostAcceptorDelegate {
    public func hostAcceptor(_ acceptor: any HostAcceptor, peerDidConnect peer: LinkPeer, path: LinkPathInfo?) {}
    public func hostAcceptor(_ acceptor: any HostAcceptor, peerDidDisconnect peer: LinkPeer) {}
    public func hostAcceptor(_ acceptor: any HostAcceptor, peerDidTimeOut peer: LinkPeer, idle: Duration) {}
    public func hostAcceptor(_ acceptor: any HostAcceptor, didChange state: HostAcceptorState) {}
    public func hostAcceptor(_ acceptor: any HostAcceptor, didReceiveAction action: JSONValue, from userID: String?) {}
}

/// Host side: accepts links from phones and hands over their channels.
public protocol HostAcceptor: AnyObject, Sendable {
    func setDelegate(_ delegate: (any HostAcceptorDelegate)?)
    func start()
    func stop()
}
