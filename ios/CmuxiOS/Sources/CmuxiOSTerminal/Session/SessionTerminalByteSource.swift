public import CmuxTerminalRenderCore
public import CmuxTerminalStream
public import Foundation

/// `TerminalByteSource` over the transport lane's `TerminalSessionSource`
/// for one terminal of a cmux session host (`.host` authority). Frames are
/// decoded here; an undecodable frame is dropped and the next bytes frame's
/// offset gap resyncs from a snapshot.
public final class SessionTerminalByteSource: TerminalByteSource {
    public let source: any TerminalSessionSource
    public let terminal: TerminalRef

    public init(source: any TerminalSessionSource, terminal: TerminalRef) {
        self.source = source
        self.terminal = terminal
    }

    public var authority: TerminalAuthority { .host }
    public var terminalID: String { terminal.terminal }

    public func open(_ viewport: TerminalViewport) async throws -> AsyncStream<TerminalSourceEvent> {
        let events = try await source.attach(terminal)
        await source.setPresence(terminal, visible: viewport.visible, cols: viewport.cols, rows: viewport.rows)
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                for await event in events {
                    if let mapped = Self.map(event) { continuation.yield(mapped) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The source event for a channel event; nil for a frame this viewer
    /// cannot decode or does not know (a later protocol revision).
    static func map(_ event: TerminalChannelEvent) -> TerminalSourceEvent? {
        switch event {
        case .frame(let data):
            guard let frame = try? TerminalFrame.decodeSkippingUnknown(data) else { return nil }
            return .frame(frame)
        case .grid(let cols, let rows, let generation): return .grid(cols: cols, rows: rows, generation: generation)
        case .snapshotThrottled(let milliseconds, let requestID):
            return .snapshotThrottled(retryAfterMilliseconds: milliseconds, requestID: requestID)
        case .path(let path, let rtt): return .path(path, rttMilliseconds: rtt)
        case .kicked(let name): return .kicked(byDisplayName: name)
        case .closed(let reason): return .closed(reason: reason)
        }
    }

    public func send(_ input: Data) async throws {
        try await source.send(input, to: terminal)
    }

    public func viewportChanged(_ viewport: TerminalViewport) async {
        await source.setPresence(terminal, visible: viewport.visible, cols: viewport.cols, rows: viewport.rows)
    }

    public func requestSnapshot(_ request: SnapshotRequest) async throws {
        try await source.requestSnapshot(request, for: terminal)
    }

    public func close() async {
        await source.detach(terminal)
    }
}
