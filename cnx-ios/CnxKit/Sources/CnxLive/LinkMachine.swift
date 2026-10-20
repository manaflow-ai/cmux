import struct CnxModel.MacDevice
import CnxTransport
import Foundation

/// The connection to the selected Mac as a pure state machine: events in,
/// effects out. `LinkController` runs the effects (dial, close, timers);
/// tests drive the machine directly.
///
/// A generation number tags every dial and timer, so a late result from a
/// dial the machine already abandoned (transport switch, Mac change) is
/// ignored.
public struct LinkMachine: Sendable {
    /// The Mac to keep a link to.
    public struct Target: Equatable, Sendable {
        public var macID: String
        public var name: String
        public var isOnline: Bool

        public init(macID: String, name: String, isOnline: Bool) {
            self.macID = macID
            self.name = name
            self.isOnline = isOnline
        }
    }

    public enum Phase: Equatable, Sendable {
        /// No Mac selected.
        case idle
        /// The selected Mac's presence is offline; no dial until it returns.
        case macOffline
        case connecting(TransportKind, attempt: Int)
        case connected(TransportKind, LinkPathKind, rttMillis: UInt32?)
        /// The last dial or link failed; the next dial is scheduled.
        case waiting(TransportKind, attempt: Int, reason: String, retryIn: Duration)
    }

    public enum Event: Equatable, Sendable {
        case target(Target?)
        case transport(TransportKind)
        /// Debug relay-only mode on or off; a change redials.
        case relayOnly(Bool)
        /// Debug UDP-blocked mode on or off; a change redials.
        case blockUDP(Bool)
        case dialSucceeded(generation: Int, path: LinkPathKind)
        case dialFailed(generation: Int, reason: String)
        /// The link reported a new path or RTT.
        case linkUpdated(generation: Int, path: LinkPathKind, rttMillis: UInt32?)
        /// The WebRTC media session beside a WireGuard link changed.
        case mediaUpdated(generation: Int, VideoMediaState)
        case linkDropped(generation: Int, reason: String)
        case retryDue(generation: Int)
        /// The app came to the foreground (or the network came back).
        case foreground
        case probeFailed(generation: Int, reason: String)
    }

    public enum Effect: Equatable, Sendable {
        case dial(generation: Int, macID: String, transport: TransportKind)
        /// Close the current link (if any) and drop its channels.
        case close
        case scheduleRetry(generation: Int, after: Duration)
        /// Ping the live link; a failure comes back as `probeFailed`.
        case probe(generation: Int)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var target: Target?
    public private(set) var transport: TransportKind
    /// Debug "simulate distant network": dials skip every direct path.
    public private(set) var relayOnly: Bool
    /// Debug "simulate a network that blocks UDP": WireGuard rides TURN over TLS.
    public private(set) var blockUDP: Bool
    public private(set) var generation = 0
    /// The current link's WebRTC media session (browser video), `off` between links.
    public private(set) var media: VideoMediaState = .off
    /// Retry delays in seconds after the silent retries; the last one repeats.
    public var backoff: [Int] = [1, 2, 4, 8, 15, 30]
    /// Failed dials retried at once, before any failure shows.
    public static let silentRetries = 1

    public init(transport: TransportKind, relayOnly: Bool = false, blockUDP: Bool = false) {
        self.transport = transport
        self.relayOnly = relayOnly
        self.blockUDP = blockUDP
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .target(let next):
            let sameMac = next?.macID == target?.macID
            target = next
            guard let next else { return reset(to: .idle) }
            if !next.isOnline { return reset(to: .macOffline) }
            if sameMac, isActive { return [] }
            return dial(attempt: 1, closing: true)
        case .transport(let next):
            guard next != transport else { return [] }
            transport = next
            guard let target, target.isOnline else { return [] }
            return dial(attempt: 1, closing: true)
        case .relayOnly(let next):
            guard next != relayOnly else { return [] }
            relayOnly = next
            guard let target, target.isOnline else { return [] }
            return dial(attempt: 1, closing: true)
        case .blockUDP(let next):
            guard next != blockUDP else { return [] }
            blockUDP = next
            // WebRTC ignores it: no redial (the next WireGuard dial uses it).
            guard transport == .wireGuard, let target, target.isOnline else { return [] }
            return dial(attempt: 1, closing: true)
        case .dialSucceeded(let gen, let path):
            guard gen == generation, case .connecting = phase else { return [] }
            phase = .connected(transport, path, rttMillis: nil)
            return []
        case .dialFailed(let gen, let reason):
            guard gen == generation, case .connecting(_, let attempt) = phase else { return [] }
            // The first failure retries at once and says nothing: most are a
            // signaling socket the service just reset (a deploy resets them
            // all) or a stale warm socket, and the next dial opens a new one.
            if attempt <= Self.silentRetries { return dial(attempt: attempt + 1, closing: false) }
            return wait(attempt: attempt, reason: reason)
        case .linkUpdated(let gen, let path, let rtt):
            guard gen == generation, case .connected(let kind, _, let oldRTT) = phase else { return [] }
            phase = .connected(kind, path, rttMillis: rtt ?? oldRTT)
            return []
        case .mediaUpdated(let gen, let state):
            guard gen == generation, phase.isConnected else { return [] }
            media = state
            return []
        case .linkDropped(let gen, _), .probeFailed(let gen, _):
            guard gen == generation, case .connected = phase else { return [] }
            // Redial at once; a failure then takes the usual retry path.
            return [.close] + dial(attempt: 1, closing: false)
        case .retryDue(let gen):
            guard gen == generation, case .waiting(_, let attempt, _, _) = phase else { return [] }
            return dial(attempt: attempt + 1, closing: false)
        case .foreground:
            switch phase {
            case .waiting(_, let attempt, _, _): return dial(attempt: attempt + 1, closing: false)
            case .connected: return [.probe(generation: generation)]
            default: return []
            }
        }
    }

    private var isActive: Bool {
        switch phase {
        case .connecting, .connected, .waiting: true
        case .idle, .macOffline: false
        }
    }

    private mutating func reset(to next: Phase) -> [Effect] {
        let wasActive = isActive
        generation += 1
        media = .off
        phase = next
        return wasActive ? [.close] : []
    }

    private mutating func dial(attempt: Int, closing: Bool) -> [Effect] {
        guard let target else { return [] }
        let wasActive = isActive
        generation += 1
        media = .off
        phase = .connecting(transport, attempt: attempt)
        let effects: [Effect] = [.dial(generation: generation, macID: target.macID, transport: transport)]
        return closing && wasActive ? [.close] + effects : effects
    }

    private mutating func wait(attempt: Int, reason: String) -> [Effect] {
        generation += 1
        media = .off
        let seconds = backoff[min(max(attempt - 1 - Self.silentRetries, 0), backoff.count - 1)]
        phase = .waiting(transport, attempt: attempt, reason: reason, retryIn: .seconds(seconds))
        return [.scheduleRetry(generation: generation, after: .seconds(seconds))]
    }
}

extension LinkMachine.Phase {
    /// One line for the Mac's section header and Settings ("Connected ·
    /// WireGuard direct · video WebRTC (TURN) · 27 ms"); `media` is the
    /// WebRTC media session beside a WireGuard link.
    public func statusLine(macName: String, media: VideoMediaState = .off) -> String? {
        switch self {
        case .idle: nil
        case .macOffline: "\(macName) is offline"
        case .connecting(let transport, let attempt):
            attempt > 1 ? "Reconnecting over \(transport.displayName)…" : "Connecting over \(transport.displayName)…"
        case .connected(let transport, let path, let rtt):
            ["Connected", "\(transport.displayName) \(path.displayName)", media.statusLabel, rtt.map { "\($0) ms" }]
                .compactMap { $0 }.joined(separator: " · ")
        case .waiting(let transport, _, let reason, let retryIn):
            "\(transport.displayName) failed: \(reason) · retrying in \(retryIn.components.seconds) s"
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

extension LinkPathKind {
    public var displayName: String {
        switch self {
        case .direct: "direct"
        case .turn: "relay (TURN)"
        case .turnTLS: "relay (TURN over TLS)"
        case .noPath: "no path"
        }
    }
}

extension LinkMachine {
    /// The Mac to dial: the remembered one, else the one already linked, else
    /// any, each online first. When the linked Mac goes offline and no other
    /// is online, the target stays on it: "cnx mini is offline", then a redial
    /// when it is back. (Falling back to the list's first Mac named a Mac
    /// last seen hours ago in the offline banner.)
    public static func target(in macs: [MacDevice], remembered: String?, current: String?) -> MacDevice? {
        macs.first { $0.id == remembered && $0.isOnline }
            ?? macs.first { $0.id == current && $0.isOnline }
            ?? macs.first(where: \.isOnline)
            ?? macs.first { $0.id == remembered }
            ?? macs.first { $0.id == current }
            ?? macs.first
    }
}
