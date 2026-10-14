import Foundation

/// The three ordered, reliable lanes of a link (PROTOCOL §1).
public enum Lane: UInt8, Sendable, CaseIterable, Hashable {
    case control = 0
    case interactive = 1
    case bulk = 2

    /// Data channel label and id used by the WebRTC transport.
    public var label: String {
        switch self {
        case .control: "ctl"
        case .interactive: "int"
        case .bulk: "blk"
        }
    }

    public init?(label: String) {
        guard let lane = Lane.allCases.first(where: { $0.label == label }) else { return nil }
        self = lane
    }
}

/// ICE candidate type of one end of the selected path.
public enum CandidateType: String, Sendable, Hashable, Codable {
    case host, srflx, prflx, relay, unknown

    public var displayName: String {
        switch self {
        case .host: "Direct (LAN)"
        case .srflx, .prflx: "Direct (NAT)"
        case .relay: "Relay"
        case .unknown: "Unknown"
        }
    }
}

/// Describes the network path a link is using.
public struct PathInfo: Sendable, Hashable {
    /// Transport name, for example `webrtc` or `loopback`.
    public var transport: String
    public var localCandidate: CandidateType?
    public var remoteCandidate: CandidateType?
    /// Round-trip time of the last `host.ping`, in milliseconds.
    public var rttMs: Double?

    public init(transport: String, localCandidate: CandidateType? = nil, remoteCandidate: CandidateType? = nil, rttMs: Double? = nil) {
        self.transport = transport; self.localCandidate = localCandidate; self.remoteCandidate = remoteCandidate; self.rttMs = rttMs
    }

    public var isRelayed: Bool { localCandidate == .relay || remoteCandidate == .relay }

    /// Short human summary, for example `Relay · 84 ms`.
    public var summary: String {
        var parts: [String] = []
        if let local = localCandidate {
            parts.append(isRelayed ? CandidateType.relay.displayName : (remoteCandidate == .host && local == .host ? CandidateType.host.displayName : local.displayName))
        } else {
            parts.append(transport)
        }
        if let rttMs { parts.append("\(Int(rttMs.rounded())) ms") }
        return parts.joined(separator: " · ")
    }
}

/// What a transport reports to its link.
public enum TransportEvent: Sendable {
    /// One `LaneCodec` chunk received on `lane`.
    case chunk(Lane, Data)
    /// The selected network path changed.
    case pathChanged(PathInfo)
    /// The transport closed. No further events follow and `events` finishes.
    case closed(reason: String?)
}

public enum TransportError: Error, Sendable, Hashable, LocalizedError {
    case closed
    case sendFailed(String)
    case connectFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .closed: "The connection is closed."
        case .sendFailed(let m): "Send failed: \(m)"
        case .connectFailed(let m): m
        case .timedOut: "The connection timed out."
        }
    }
}

/// A transport moves `LaneCodec` chunks over three ordered reliable lanes.
/// It is already open when handed to a `Link`.
public protocol LinkTransport: AnyObject, Sendable {
    /// Incoming chunks and state changes, in arrival order. Single consumer.
    var events: AsyncStream<TransportEvent> { get }
    /// Enqueues the chunks of one message on `lane`, atomically and in order.
    func send(_ chunks: [Data], on lane: Lane) throws
    /// Closes the transport. `events` then yields `.closed` and finishes.
    func close()
    /// The current network path.
    func pathInfo() async -> PathInfo
}

/// Opens a transport to a host. `HostConnection` calls it on every
/// (re)connect attempt.
public protocol Connector: Sendable {
    func connect(hostId: String) async throws -> any LinkTransport
}
