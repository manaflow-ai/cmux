import Foundation

/// A logical channel on a link. Both lanes are reliable and ordered; they are
/// separate so a burst of terminal output never delays a control reply.
public enum Lane: String, Sendable, Hashable, CaseIterable {
    /// JSON `Envelope`s.
    case control
    /// Binary `BulkFrame`s.
    case bulk
}

public enum LinkState: Sendable, Hashable {
    case connecting
    /// Connected; `route` says how (for display and diagnostics), e.g.
    /// `direct`, `relay`.
    case connected(route: String)
    case disconnected(reason: String?)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// One live connection between a phone and a Mac, independent of transport.
///
/// WebRTC, a relay socket or an in-memory pair all implement this. Everything
/// above it (`RPCPeer`, the host services, the app) only sees lanes.
public protocol PeerLink: AnyObject, Sendable {
    /// The remote peer's signaling id.
    var remotePeerID: String { get }
    /// Current state, then every change, until the link closes.
    var states: AsyncStream<LinkState> { get }
    /// Messages from the remote peer, until the link closes.
    var messages: AsyncStream<(Lane, Data)> { get }
    func send(_ data: Data, on lane: Lane) throws
    func close()
}

/// Dials hosts from the phone.
public protocol PeerDialer: Sendable {
    func dial(peerID: String) async throws -> PeerLink
}

/// Accepts phones on the Mac.
public protocol PeerAcceptor: Sendable {
    var incoming: AsyncStream<PeerLink> { get }
}

public struct TransportError: Error, Sendable, Hashable, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
