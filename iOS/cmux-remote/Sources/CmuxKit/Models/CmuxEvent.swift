public import Foundation

/// One frame of the cmux events stream as described in `docs/events.md`.
///
/// The stream produces three frame shapes — `ack`, `event`, `heartbeat`. We
/// preserve the full payload as raw JSON because the catalog is large and
/// adds new entries over time; consumers project the typed payloads they need.
public enum CmuxEventFrame: Sendable {
    case ack(Ack)
    case event(Event)
    case heartbeat(Heartbeat)

    public struct Ack: Sendable, Hashable {
        public let bootID: String
        public let subscriptionID: String
        public let heartbeatIntervalSeconds: Double
        public let replayCount: Int
        public let resume: Resume
        public let filterNames: [String]
        public let filterCategories: [String]

        public struct Resume: Sendable, Hashable {
            public let afterSeq: Int?
            public let requestedAfterSeq: Int?
            public let oldestSeq: Int?
            public let latestSeq: Int?
            public let nextSeq: Int?
            public let gap: Bool
        }
    }

    public struct Event: Sendable, Hashable {
        public let bootID: String
        public let seq: Int
        public let id: String
        public let name: String
        public let category: String
        public let source: String
        public let occurredAt: Date
        public let workspaceID: WorkspaceID?
        public let surfaceID: SurfaceID?
        public let paneID: PaneID?
        public let windowID: WindowID?
        /// The raw payload as canonical JSON-data — we deliberately keep it as
        /// data so the reactor can decode lazily / by category.
        public let payload: Data
    }

    public struct Heartbeat: Sendable, Hashable {
        public let bootID: String
        public let subscriptionID: String
        public let latestSeq: Int
        public let occurredAt: Date
    }
}

extension CmuxEventFrame {
    public var seq: Int? {
        if case .event(let event) = self { return event.seq }
        return nil
    }

    public var bootID: String {
        switch self {
        case .ack(let ack): return ack.bootID
        case .event(let event): return event.bootID
        case .heartbeat(let hb): return hb.bootID
        }
    }
}

/// Cursor we persist between app launches / reconnections so we resume cleanly
/// per the documented cmux event-stream resume contract.
public struct CmuxEventCursor: Codable, Hashable, Sendable {
    public var bootID: String?
    public var seq: Int?

    public init(bootID: String? = nil, seq: Int? = nil) {
        self.bootID = bootID
        self.seq = seq
    }

    public mutating func advance(to event: CmuxEventFrame.Event) {
        bootID = event.bootID
        seq = event.seq
    }

    public mutating func reset(for ack: CmuxEventFrame.Ack) {
        // If the boot id changed, we lost continuity — discard the seq so the
        // caller refreshes state via snapshots.
        if let known = bootID, known != ack.bootID {
            seq = nil
        }
        bootID = ack.bootID
    }
}
