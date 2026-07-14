import Foundation

/// Correlates cmux-tui command responses while streaming interleaved attach events.
public actor CmuxProtocolClient {
    private let transport: any CmuxTransport
    private let eventStream: AsyncStream<CmuxAttachEvent>
    private let eventContinuation: AsyncStream<CmuxAttachEvent>.Continuation
    private var pending: [UInt64: CheckedContinuation<Data, Error>] = [:]
    private var nextID: UInt64 = 1
    private var receiveTask: Task<Void, Never>?
    private var connected = false

    /// Creates a protocol client around an injected transport.
    /// - Parameter transport: The full-duplex transport implementation.
    public init(transport: any CmuxTransport) {
        self.transport = transport
        let pair = AsyncStream<CmuxAttachEvent>.makeStream(bufferingPolicy: .unbounded)
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    /// Opens the transport and sends the optional authentication preamble first.
    /// - Parameter token: The WebSocket token, if required by the server.
    public func connect(token: String?) async throws {
        guard !connected else { return }
        try await transport.connect()

        if let token {
            let preamble = try JSONEncoder().encode(["auth": ["token": token]])
            try await transport.send(preamble)
        }

        connected = true
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    /// Returns the buffered stream of decoded attach events.
    /// - Returns: An ordered, unbounded event stream.
    public func events() -> AsyncStream<CmuxAttachEvent> {
        eventStream
    }

    /// Closes the connection and finishes all observers.
    public func close() async {
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()
        finish(with: CancellationError())
        connected = false
    }

    func identify() async throws -> CmuxIdentifyResponse {
        try await request(CmuxCommandRequest(id: 0, cmd: "identify"))
    }

    func setClientInfo(name: String, kind: String) async throws {
        _ = try await request(
            CmuxCommandRequest(id: 0, cmd: "set-client-info", name: name, kind: kind),
            as: CmuxEmptyResponse.self
        )
    }

    func listWorkspaces() async throws -> CmuxWorkspaceTree {
        try await request(CmuxCommandRequest(id: 0, cmd: "list-workspaces"))
    }

    func attachSurface(_ surface: UInt64, includeByteMode: Bool) async throws {
        _ = try await request(
            CmuxCommandRequest(
                id: 0,
                cmd: "attach-surface",
                surface: surface,
                mode: includeByteMode ? "bytes" : nil
            ),
            as: CmuxEmptyResponse.self
        )
    }

    func sendBytes(_ bytes: Data, surface: UInt64) async throws {
        _ = try await request(
            CmuxCommandRequest(
                id: 0,
                cmd: "send",
                surface: surface,
                bytes: bytes.base64EncodedString()
            ),
            as: CmuxEmptyResponse.self
        )
    }

    func sendText(_ text: String, surface: UInt64) async throws {
        _ = try await request(
            CmuxCommandRequest(id: 0, cmd: "send", surface: surface, text: text),
            as: CmuxEmptyResponse.self
        )
    }

    func resizeSurface(_ surface: UInt64, columns: UInt16, rows: UInt16) async throws {
        _ = try await request(
            CmuxCommandRequest(
                id: 0,
                cmd: "resize-surface",
                surface: surface,
                cols: columns,
                rows: rows
            ),
            as: CmuxEmptyResponse.self
        )
    }

    private func request<Payload: Decodable & Sendable>(
        _ request: CmuxCommandRequest,
        as _: Payload.Type = Payload.self
    ) async throws -> Payload {
        guard connected else {
            throw CmuxProtocolError.transportState("protocol client is not connected")
        }

        let id = nextID
        nextID &+= 1
        let request = CmuxCommandRequest(
            id: id,
            cmd: request.cmd,
            name: request.name,
            kind: request.kind,
            surface: request.surface,
            mode: request.mode,
            text: request.text,
            bytes: request.bytes,
            cols: request.cols,
            rows: request.rows
        )
        let encoded = try JSONEncoder().encode(request)
        let responseData = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [transport] in
                do {
                    try await transport.send(encoded)
                } catch {
                    self.failRequest(id: id, error: error)
                }
            }
        }

        let response = try JSONDecoder().decode(CmuxResponseEnvelope<Payload>.self, from: responseData)
        guard response.ok else {
            throw CmuxProtocolError.command(response.error ?? "unknown server error")
        }
        guard let payload = response.data else {
            throw CmuxProtocolError.malformedPayload("response \(id) has no data")
        }
        return payload
    }

    private func failRequest(id: UInt64, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let data = try await transport.receive()
                let header = try JSONDecoder().decode(CmuxInboundHeader.self, from: data)

                if header.event != nil {
                    eventContinuation.yield(try JSONDecoder().decode(CmuxAttachEvent.self, from: data))
                } else if let id = header.id {
                    pending.removeValue(forKey: id)?.resume(returning: data)
                } else if header.ok == false {
                    throw CmuxProtocolError.command(header.error ?? "uncorrelated server error")
                } else {
                    throw CmuxProtocolError.malformedPayload("message has neither event nor id")
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            finish(with: error)
        }
    }

    private func finish(with error: Error) {
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
        eventContinuation.finish()
    }
}
