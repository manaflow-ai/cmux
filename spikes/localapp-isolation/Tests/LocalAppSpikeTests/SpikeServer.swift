import Foundation
import Network

/// A loopback WebSocket server that stands in for the acpmux daemon. It answers `initialize`,
/// records each client's first frame and Origin, and streams frames that the page acknowledges.
/// Times are `DispatchTime` nanoseconds on the server queue.
final class SpikeServer: @unchecked Sendable {
    final class Peer {
        let connection: NWConnection
        var name = ""
        var origin: String?
        var firstFrame: String?
        var sendTimes: [UInt64] = []
        var ackTimes: [UInt64] = []
        var count = 0
        var window = 0
        var next = 0
        var acked = 0
        var done: CheckedContinuation<Void, Never>?
        init(connection: NWConnection) { self.connection = connection }
    }

    let queue = DispatchQueue(label: "spike.server", qos: .userInteractive)
    private var listener: NWListener?
    private var lastOrigin: String?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var named: [String: Peer] = [:]
    private var pad = String(repeating: "x", count: 200)
    private(set) var port: UInt16 = 0

    func start() async throws {
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.setClientRequestHandler(queue) { [weak self] _, headers in
            self?.lastOrigin = headers.first { $0.name.lowercased() == "origin" }?.value
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; continuation.resume()
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    var url: URL { URL(string: "ws://127.0.0.1:\(port)/")! }

    func stop() {
        listener?.cancel()
        queue.sync { for peer in peers.values { peer.connection.cancel() } }
    }

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection: connection)
        peers[ObjectIdentifier(connection)] = peer
        connection.start(queue: queue)
        receive(peer)
    }

    private func receive(_ peer: Peer) {
        peer.connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            self.handle(peer, String(decoding: data, as: UTF8.self))
            self.receive(peer)
        }
    }

    private func handle(_ peer: Peer, _ text: String) {
        if text.hasPrefix("{\"a\":") {
            let now = DispatchTime.now().uptimeNanoseconds
            guard let seq = Int(text.dropFirst(5).dropLast()), seq < peer.ackTimes.count, peer.ackTimes[seq] == 0 else { return }
            peer.ackTimes[seq] = now
            peer.acked += 1
            if peer.next < peer.count { send(peer, seq: peer.next); peer.next += 1 }
            if peer.acked == peer.count { peer.done?.resume(); peer.done = nil }
            return
        }
        if peer.firstFrame == nil {
            peer.firstFrame = text
            peer.origin = lastOrigin
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            let params = object?["params"] as? [String: Any]
            peer.name = (params?["clientInfo"] as? [String: Any])?["name"] as? String ?? "?"
            named[peer.name] = peer
            write(peer, #"{"jsonrpc":"2.0","id":0,"result":{"_meta":{"acpmux":{"origin":"local"}}}}"#)
        }
    }

    private func frame(_ seq: Int) -> String {
        #"{"jsonrpc":"2.0","method":"session/update","params":{"s":"# + String(seq)
            + #","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":""# + pad + #""}}}}"#
    }

    private func send(_ peer: Peer, seq: Int) {
        let text = frame(seq)
        peer.sendTimes[seq] = DispatchTime.now().uptimeNanoseconds
        write(peer, text)
    }

    private func write(_ peer: Peer, _ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        peer.connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// What a client sent first, and its Origin header.
    func first(of name: String) -> (frame: String?, origin: String?) {
        queue.sync { (named[name]?.firstFrame, named[name]?.origin) }
    }

    /// Streams `count` frames to client `name`, at most `window` unacknowledged. Returns each
    /// frame's send-to-acknowledgement time and the time from the first send to the last ack.
    func stream(to name: String, count: Int, window: Int) async -> (latencies: [UInt64], total: UInt64) {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard let peer = self.named[name] else { continuation.resume(); return }
                peer.sendTimes = Array(repeating: 0, count: count)
                peer.ackTimes = Array(repeating: 0, count: count)
                peer.count = count
                peer.window = window
                peer.acked = 0
                peer.next = 0
                peer.done = continuation
                while peer.next < min(window, count) { self.send(peer, seq: peer.next); peer.next += 1 }
            }
        }
        return queue.sync {
            guard let peer = named[name] else { return ([], 0) }
            let latencies = zip(peer.sendTimes, peer.ackTimes).map { $1 &- $0 }
            return (latencies, (peer.ackTimes.max() ?? 0) &- (peer.sendTimes.min() ?? 0))
        }
    }
}
