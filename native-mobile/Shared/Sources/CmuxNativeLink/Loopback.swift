import Foundation
import CmuxNativeWire
import Network
import Synchronization

// Development transport: one TCP connection per channel. The first line a
// client sends is a hello, `{"label":"svc","peer":"<id>"}`; after that both
// sides exchange the same messages a data channel carries (newline lines and
// `{"frag":…}` envelopes).

struct LoopbackHello: Codable, Sendable {
    var label: String
    var peer: String
}

/// `LinkChannel` over one `NWConnection`.
final class TCPLinkChannel: LinkChannel {
    let label: String
    private let connection: NWConnection
    private let lines = IncomingLines()
    private let framer = LineFramer()
    private let sendLock = SendSerializer()
    private let closed = Atomic<Bool>(false)
    private let onClose: Mutex<(@Sendable () -> Void)?>

    var incoming: AsyncStream<Data> { lines.stream }

    init(label: String, connection: NWConnection, leftover: Data = Data(), onClose: (@Sendable () -> Void)? = nil) {
        self.label = label
        self.connection = connection
        self.onClose = Mutex(onClose)
        var splitter = ByteStreamLineSplitter(maximumLineBytes: 64 << 20)
        if !leftover.isEmpty, let first = try? splitter.append(leftover) {
            for line in first { lines.deliver(message: line) }
        }
        receive(splitter: splitter)
    }

    private func receive(splitter: ByteStreamLineSplitter) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var splitter = splitter
            if let data, !data.isEmpty {
                guard let parts = try? splitter.append(data) else { return self.close() }
                for line in parts where !self.lines.deliver(message: line) { return self.close() }
            }
            if isComplete || error != nil { return self.close() }
            self.receive(splitter: splitter)
        }
    }

    func send(_ data: Data) async throws {
        guard !closed.load(ordering: .acquiring) else { throw LinkError.channelClosed }
        let messages = framer.encode(line: data)
        try await sendLock.run {
            for message in messages { try await self.connection.sendAsync(message) }
        }
    }

    func close() {
        guard !closed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        connection.cancel()
        lines.finish()
        if let onClose = onClose.withLock({ c in defer { c = nil }; return c }) { onClose() }
    }
}

extension NWConnection {
    func sendAsync(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    /// Starts the connection and waits for `.ready`.
    func startAndWait(queue: DispatchQueue, timeout: Duration = .seconds(10)) async throws {
        let gate = AsyncGate()
        stateUpdateHandler = { state in
            switch state {
            case .ready: gate.open()
            case .failed(let error): gate.fail(LinkError(code: "connect_failed", message: "\(error)"))
            case .waiting(let error): gate.fail(LinkError(code: "connect_failed", message: "\(error)"))
            case .cancelled: gate.fail(.closed)
            default: break
            }
        }
        start(queue: queue)
        do { try await gate.wait(timeout: timeout, what: "tcp connect") } catch {
            cancel()
            throw error
        }
    }
}

/// Phone side of the loopback transport.
public final class LoopbackHostLink: HostLink {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let peerID = UUID().uuidString.lowercased()
    private let queue = DispatchQueue(label: "cmux.native.loopback.link")
    private let broadcaster = StateBroadcaster<LinkState>(.connected(.direct))
    private let channels = Mutex<[ObjectIdentifier: TCPLinkChannel]>([:])

    public init(host: String = "127.0.0.1", port: UInt16) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    public var state: AsyncStream<LinkState> { broadcaster.stream() }

    public func openChannel(label: String) async throws -> any LinkChannel {
        if broadcaster.current == .closed { throw LinkError.closed }
        let connection = NWConnection(host: host, port: port, using: .tcp)
        try await connection.startAndWait(queue: queue)
        var hello = try JSONEncoder().encode(LoopbackHello(label: label, peer: peerID))
        hello.append(0x0A)
        try await connection.sendAsync(hello)
        let key = ObjectIdentifier(connection)
        let channel = TCPLinkChannel(label: label, connection: connection, onClose: { [weak self] in
            _ = self?.channels.withLock { $0.removeValue(forKey: key) }
        })
        channels.withLock { $0[key] = channel }
        return channel
    }

    public func close() {
        broadcaster.finish(with: .closed)
        let all = channels.withLock { c in
            defer { c = [:] }
            return Array(c.values)
        }
        for channel in all { channel.close() }
    }
}

/// Host side of the loopback transport (binds 127.0.0.1 by default).
public final class LoopbackHostAcceptor: HostAcceptor {
    private let requestedPort: UInt16
    private let bindHost: String
    private let queue = DispatchQueue(label: "cmux.native.loopback.acceptor")
    private let delegate = Mutex<(any HostAcceptorDelegate)?>(nil)
    private let listener = Mutex<NWListener?>(nil)
    private let ready = AsyncGate()

    /// `port` 0 picks a free port; read it from `port()` after `start()`.
    public init(port: UInt16 = 0, bindHost: String = "127.0.0.1") {
        self.requestedPort = port
        self.bindHost = bindHost
    }

    public func setDelegate(_ delegate: (any HostAcceptorDelegate)?) {
        self.delegate.withLock { $0 = delegate }
    }

    public func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost),
                                                      port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        parameters.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: parameters) else {
            ready.fail(LinkError(code: "listen_failed", message: "cannot listen on \(bindHost):\(requestedPort)"))
            return
        }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready.open()
                self.notify { $0.hostAcceptor($1, didChange: .listening) }
            case .failed(let error):
                self.ready.fail(LinkError(code: "listen_failed", message: "\(error)"))
                self.notify { $0.hostAcceptor($1, didChange: .failed("\(error)")) }
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.withLock { $0 = l }
        l.start(queue: queue)
    }

    /// Waits for the listener and returns its port.
    public func port() async throws -> UInt16 {
        try await ready.wait(timeout: .seconds(10), what: "listen")
        return listener.withLock { $0?.port?.rawValue } ?? 0
    }

    public func stop() {
        listener.withLock { l in
            l?.cancel()
            l = nil
        }
        notify { $0.hostAcceptor($1, didChange: .stopped) }
    }

    private func notify(_ body: (any HostAcceptorDelegate, any HostAcceptor) -> Void) {
        guard let d = delegate.withLock({ $0 }) else { return }
        body(d, self)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHello(connection, buffer: Data())
    }

    private func readHello(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let helloLine = buffer[..<newline]
                let rest = Data(buffer[(newline + 1)...])
                guard let hello = try? JSONDecoder().decode(LoopbackHello.self, from: helloLine) else {
                    return connection.cancel()
                }
                let channel = TCPLinkChannel(label: hello.label, connection: connection, leftover: rest)
                self.notify { $0.hostAcceptor($1, didOpen: channel, from: LinkPeer(sid: hello.peer, userID: nil)) }
                return
            }
            if isComplete || error != nil || buffer.count > 4096 { return connection.cancel() }
            self.readHello(connection, buffer: buffer)
        }
    }
}
