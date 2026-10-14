import Foundation

/// Which transport carries the link. Users switch it in Settings → Connection.
public enum TransportKind: String, CaseIterable, Codable, Sendable {
    case webRTC = "webrtc"
    case wireGuard = "wireguard"

    public var displayName: String {
        switch self {
        case .webRTC: "WebRTC"
        case .wireGuard: "WireGuard"
        }
    }
}

/// How the bytes currently travel.
public enum LinkPathKind: String, Sendable {
    case direct, relay, turn
}

/// Connection state shown in banners and Settings.
public enum LinkState: Equatable, Sendable {
    case idle
    case connecting(TransportKind)
    case connected(TransportKind, LinkPathKind, rttMillis: UInt32?)
    case disconnected(reason: String)
}

/// A transport-agnostic connection to one Mac. Implementations: `FFIMacLink`
/// (Rust cnx-link over WebRTC or WireGuard) and `MockMacLink`.
public protocol MacLink: AnyObject, Sendable {
    var transport: TransportKind { get }
    var states: AsyncStream<LinkState> { get }
    /// Opens a named service channel (`daemon`, `acpmux`, `file`, `echo`).
    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel
    /// Opens a channel on the input lane (PROTOCOL.md "Lanes"): terminal
    /// keystrokes and their replies, which then never wait behind bulk
    /// output. A link without one opens an ordinary channel.
    func openInputChannel(service: String, args: [String: String]) async throws -> any LinkChannel
    func ping() async throws -> UInt32
    func close() async
}

extension MacLink {
    public func openInputChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        try await openChannel(service: service, args: args)
    }
}

/// One multiplexed channel inside a link.
public protocol LinkChannel: AnyObject, Sendable {
    var id: UInt32 { get }
    func send(_ data: Data) async throws
    /// The next message, or nil once the channel is closed.
    func receive() async throws -> Data?
    func close(code: String, reason: String) async
    /// Why the Mac closed the channel, once `receive()` returned nil (nil: unknown).
    var closedBy: LinkError? { get }
}

public extension LinkChannel {
    var closedBy: LinkError? { nil }
}

public struct LinkError: Error, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Everything needed to dial a Mac.
public struct LinkEndpoint: Sendable, Hashable {
    public var baseURL: URL
    public var teamID: String
    public var deviceID: String
    public var macDeviceID: String
    /// Debug "simulate distant network": no direct path. WebRTC uses only
    /// TURN (path `turn`), WireGuard only the service's relay (path `relay`).
    public var relayOnly: Bool

    public init(baseURL: URL, teamID: String, deviceID: String, macDeviceID: String, relayOnly: Bool = false) {
        self.baseURL = baseURL
        self.teamID = teamID
        self.deviceID = deviceID
        self.macDeviceID = macDeviceID
        self.relayOnly = relayOnly
    }
}

/// Dials a link with a fresh access token for the chosen transport.
public protocol MacLinkDialer: Sendable {
    func dial(_ endpoint: LinkEndpoint, transport: TransportKind, accessToken: String) async throws -> any MacLink
    /// Warms what the next dial in this team needs (signaling socket, ICE
    /// servers) before any Mac is asked for. Returns the steps as
    /// `name=ms` pairs for the timing log.
    func prewarm(baseURL: URL, teamID: String, deviceID: String, accessToken: String) async -> [(String, Double)]
    /// Forgets warm sockets and cached servers (sign-out).
    func resetWarmState() async
}

extension MacLinkDialer {
    public func prewarm(baseURL: URL, teamID: String, deviceID: String, accessToken: String) async -> [(String, Double)] { [] }
    public func resetWarmState() async {}
}

/// A dialed link that can say how its dial went (`name`, ms since the dial began).
public protocol TimedMacLink: MacLink {
    var timings: [(String, Double)] { get }
}
