import Foundation

/// What a link delivers upward: whole lane messages and state.
public enum LinkEvent: Sendable {
    case message(Lane, Data)
    case pathChanged(PathInfo)
    case closed(reason: String?)
}

/// Whole-message lanes over a chunk transport. Applies `LaneCodec` in both
/// directions; transport agnostic.
public final class Link: Sendable {
    public let transport: any LinkTransport
    public let codec: LaneCodec
    /// Incoming messages. Single consumer. Finishes after `.closed`.
    public let events: AsyncStream<LinkEvent>

    public init(transport: any LinkTransport, codec: LaneCodec = LaneCodec()) {
        self.transport = transport
        self.codec = codec
        let (stream, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
        self.events = stream
        Task { [transport, codec] in
            var reassemblers = Dictionary(uniqueKeysWithValues: Lane.allCases.map { ($0, codec.makeReassembler()) })
            var closedReason: String?? = nil
            for await event in transport.events {
                switch event {
                case .chunk(let lane, let chunk):
                    do {
                        if let message = try reassemblers[lane]!.push(chunk) {
                            continuation.yield(.message(lane, message))
                        }
                    } catch {
                        closedReason = .some("Protocol error on \(lane.label): \(error)")
                        transport.close()
                    }
                case .pathChanged(let info):
                    continuation.yield(.pathChanged(info))
                case .closed(let reason):
                    if closedReason == nil { closedReason = .some(reason) }
                }
            }
            continuation.yield(.closed(reason: closedReason ?? nil))
            continuation.finish()
        }
    }

    /// Sends one whole message on `lane`.
    public func send(_ message: Data, on lane: Lane) throws {
        try transport.send(codec.fragment(message), on: lane)
    }

    public func close() {
        transport.close()
    }
}
