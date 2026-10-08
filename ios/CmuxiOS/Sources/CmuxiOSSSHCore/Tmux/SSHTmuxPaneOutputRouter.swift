import Foundation

/// Routes one tmux window's per-pane byte streams to independent Ghostty
/// surfaces. The router is deliberately carrier-independent: a control-mode
/// adapter or an owner RPC can feed it the same host-issued pane identity.
///
/// A pane must be hydrated with a complete snapshot before live bytes are
/// accepted. This makes reconnects deterministic and prevents output from a
/// replaced server from being appended to a parser that still owns the old
/// generation. Pane ids are renderer/parser identities; layout changes update
/// frames without resetting a surviving stream.
public struct SSHTmuxPaneOutputRouter: Sendable {
    public static let maximumChunkBytes = 16 * 1024
    public static let maximumSnapshotBytes = 256 * 1024
    public static let maximumQueuedBytesPerPane = 256 * 1024
    public static let maximumQueuedBytes = 1024 * 1024

    public struct Identity: Hashable, Sendable {
        public let server: SSHTmuxServerEpoch
        public let windowID: String

        public init?(server: SSHTmuxServerEpoch, windowID: String) {
            guard SSHTmuxWindow.isValidID(windowID, prefix: "@") else { return nil }
            self.server = server
            self.windowID = windowID
        }
    }

    public struct Delivery: Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable {
            case snapshot
            case live
        }

        public let paneID: String
        /// Nondecreasing per-pane sequence assigned to each bounded chunk as
        /// bytes enter the queue. A delivery may split one chunk when the
        /// caller asks `drain` for a smaller budget and retains that chunk's
        /// sequence. It resets on reconnect.
        public let sequence: UInt64
        public let kind: Kind
        public let bytes: Data
    }

    public struct StreamStatus: Hashable, Sendable {
        public enum Phase: String, Hashable, Sendable {
            case awaitingSnapshot
            case live
            case overflowed
        }

        public let paneID: String
        public let frame: SSHTmuxLayout.Frame
        public let phase: Phase
        public let queuedBytes: Int
        public let nextSequence: UInt64
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case staleServer
        case wrongWindow
        case unknownPane
        case awaitingSnapshot
        case alreadyHydrated
        case snapshotTooLarge
        case chunkTooLarge
        case emptyInput
        case bufferOverflow
        case streamOverflowed
    }

    private struct Chunk: Hashable, Sendable {
        let sequence: UInt64
        let kind: Delivery.Kind
        let bytes: Data
    }

    private struct Stream: Hashable, Sendable {
        var frame: SSHTmuxLayout.Frame
        var phase: StreamStatus.Phase = .awaitingSnapshot
        var nextSequence: UInt64 = 0
        var queuedBytes = 0
        var chunks: [Chunk] = []
    }

    public let identity: Identity
    private var composition: SSHTmuxPaneComposition
    private var streams: [String: Stream]
    private var totalQueuedBytes = 0

    public init?(identity: Identity, projection: SSHTmuxPaneProjection) {
        guard projection.panes.count <= SSHTmuxPaneProjection.maximumPanes else { return nil }
        self.identity = identity
        self.composition = SSHTmuxPaneComposition(projection: projection)
        self.streams = Dictionary(uniqueKeysWithValues: projection.panes.map {
            ($0.id, Stream(frame: $0.frame))
        })
    }

    public var projection: SSHTmuxPaneProjection { composition.projection }
    public var panes: [SSHTmuxPaneProjection.Pane] { composition.panes }
    public var queuedBytes: Int { totalQueuedBytes }

    /// Returns the current state for one host-issued pane id.
    public func status(for paneID: String) -> StreamStatus? {
        streams[paneID].map {
            StreamStatus(paneID: paneID, frame: $0.frame, phase: $0.phase,
                         queuedBytes: $0.queuedBytes, nextSequence: $0.nextSequence)
        }
    }

    /// Starts a fresh hydration barrier for every pane. Existing parser bytes
    /// are discarded only because a reconnect must begin from a new host
    /// snapshot; the caller receives no silently replayed or reordered data.
    public mutating func resetForReconnect(identity: Identity) throws {
        try validate(identity)
        totalQueuedBytes = 0
        for paneID in Array(streams.keys) {
            guard var stream = streams[paneID] else { continue }
            stream.phase = .awaitingSnapshot
            stream.nextSequence = 0
            stream.queuedBytes = 0
            stream.chunks.removeAll(keepingCapacity: false)
            streams[paneID] = stream
        }
    }

    /// Reconciles a newer validated host layout. A surviving pane retains its
    /// parser queue and sequence; removed panes are discarded before additions
    /// so stale output can never be routed to a replacement id.
    @discardableResult
    public mutating func reconcile(to next: SSHTmuxPaneProjection) -> [SSHTmuxPaneComposition.Change] {
        let changes = composition.reconcile(to: next)
        let nextIDs = Set(next.panes.map(\.id))
        for paneID in Array(streams.keys) where !nextIDs.contains(paneID) {
            if let stream = streams.removeValue(forKey: paneID) { totalQueuedBytes -= stream.queuedBytes }
        }
        for pane in next.panes {
            if var stream = streams[pane.id] {
                stream.frame = pane.frame
                streams[pane.id] = stream
            } else {
                streams[pane.id] = Stream(frame: pane.frame)
            }
        }
        return changes
    }

    /// Enqueues a complete parser snapshot for a pane. The bytes are split
    /// into bounded deliveries, with one increasing sequence per chunk.
    public mutating func hydrate(identity: Identity, paneID: String, snapshot: Data) throws {
        try validate(identity, paneID: paneID)
        guard !snapshot.isEmpty else { throw Error.emptyInput }
        guard snapshot.count <= Self.maximumSnapshotBytes else { throw Error.snapshotTooLarge }
        guard var stream = streams[paneID] else { throw Error.unknownPane }
        guard stream.phase == .awaitingSnapshot else {
            if stream.phase == .overflowed { throw Error.streamOverflowed }
            throw Error.alreadyHydrated
        }
        do {
            try append(snapshot, kind: .snapshot, to: &stream)
        } catch {
            // Preserve the terminal overflow state even though the caller
            // receives the refusal synchronously.
            streams[paneID] = stream
            throw error
        }
        stream.phase = .live
        streams[paneID] = stream
    }

    /// Enqueues live `%output` bytes after snapshot hydration. Unknown or
    /// stale pane records fail closed; no data is dropped to make progress.
    public mutating func ingest(identity: Identity, paneID: String, bytes: Data) throws {
        try validate(identity, paneID: paneID)
        guard !bytes.isEmpty else { throw Error.emptyInput }
        guard bytes.count <= Self.maximumSnapshotBytes else { throw Error.chunkTooLarge }
        guard var stream = streams[paneID] else { throw Error.unknownPane }
        guard stream.phase == .live else {
            if stream.phase == .overflowed { throw Error.streamOverflowed }
            throw Error.awaitingSnapshot
        }
        do {
            try append(bytes, kind: .live, to: &stream)
        } catch {
            streams[paneID] = stream
            throw error
        }
        streams[paneID] = stream
    }

    /// Drains at most `maximumBytes` while preserving chunk and sequence order.
    /// A caller may render each delivery into the pane's Ghostty surface
    /// without ever combining bytes from different parser identities.
    public mutating func drain(paneID: String, maximumBytes: Int = Self.maximumChunkBytes) -> [Delivery] {
        guard var stream = streams[paneID], maximumBytes > 0 else { return [] }
        var remaining = min(maximumBytes, Self.maximumQueuedBytesPerPane)
        var deliveries: [Delivery] = []
        while remaining > 0, !stream.chunks.isEmpty {
            let chunk = stream.chunks[0]
            let count = min(chunk.bytes.count, remaining)
            let bytes = chunk.bytes.prefix(count)
            if count == chunk.bytes.count {
                stream.chunks.removeFirst()
            } else {
                stream.chunks[0] = Chunk(sequence: chunk.sequence, kind: chunk.kind,
                                         bytes: Data(chunk.bytes.dropFirst(count)))
            }
            stream.queuedBytes -= count
            totalQueuedBytes -= count
            deliveries.append(Delivery(paneID: paneID, sequence: chunk.sequence,
                                       kind: chunk.kind, bytes: Data(bytes)))
            remaining -= count
        }
        streams[paneID] = stream
        return deliveries
    }

    /// Input routing is available only after the target pane has a parser
    /// snapshot. Divider cells and panes still waiting for hydration return
    /// nil, so a gesture cannot mutate stale or uninitialized remote state.
    public func inputTarget(atColumn column: Int, row: Int) -> SSHTmuxPaneComposition.InputTarget? {
        guard let target = composition.inputTarget(atColumn: column, row: row),
              streams[target.paneID]?.phase == .live else { return nil }
        return target
    }

    private mutating func append(_ bytes: Data, kind: Delivery.Kind, to stream: inout Stream) throws {
        let chunks = stride(from: 0, to: bytes.count, by: Self.maximumChunkBytes).map {
            bytes.subdata(in: $0..<min($0 + Self.maximumChunkBytes, bytes.count))
        }
        let incoming = bytes.count
        guard stream.queuedBytes + incoming <= Self.maximumQueuedBytesPerPane,
              totalQueuedBytes + incoming <= Self.maximumQueuedBytes else {
            stream.phase = .overflowed
            stream.chunks.removeAll(keepingCapacity: false)
            totalQueuedBytes -= stream.queuedBytes
            stream.queuedBytes = 0
            throw Error.bufferOverflow
        }
        for chunk in chunks {
            let sequence = stream.nextSequence
            stream.nextSequence &+= 1
            stream.chunks.append(Chunk(sequence: sequence, kind: kind, bytes: chunk))
        }
        stream.queuedBytes += incoming
        totalQueuedBytes += incoming
    }

    private func validate(_ candidate: Identity, paneID: String? = nil) throws {
        guard candidate.server == identity.server else { throw Error.staleServer }
        guard candidate.windowID == identity.windowID else { throw Error.wrongWindow }
        if let paneID {
            guard SSHTmuxWindow.isValidID(paneID, prefix: "%") else { throw Error.unknownPane }
        }
    }
}
