import Foundation
import Network
import CmuxCloud

/// A small HTTP origin used to prove WebKit reaches the selected local forward
/// and never falls through to a client service on the remote URL's port.
@MainActor
final class CloudLoopbackOriginTestServer {
    struct Request: Sendable {
        let method: String
        let target: String
        let host: String
        let body: String
    }

    let marker: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cmux.tests.ssh-loopback-origin")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var port: UInt16 = 0
    private(set) var requests: [Request] = []
    private var stopped = false

    init(marker: String) throws {
        self.marker = marker
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        let ready = CloudLinkFirstValue<UInt16>()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready: ready.resolve(listener.port?.rawValue)
            case .failed, .cancelled: ready.resolve(nil)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections[ObjectIdentifier(connection)] = connection
                await self.serve(connection)
            }
        }
        listener.start(queue: queue)
        guard let port = await ready.result, port > 0 else {
            stop()
            throw NSError(domain: "CloudLoopbackOriginTestServer", code: 1)
        }
        self.port = port
    }

    func stop() {
        stopped = true
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func serve(_ connection: NWConnection) async {
        defer {
            connection.cancel()
            connections.removeValue(forKey: ObjectIdentifier(connection))
        }
        do {
            try await connection.startAndWaitUntilReady(queue: queue)
            var data = Data()
            let separator = Data("\r\n\r\n".utf8)
            while data.range(of: separator) == nil {
                let chunk = try await connection.receiveChunk(maximumLength: 16_384)
                if let bytes = chunk.data { data.append(bytes) }
                if chunk.isComplete && data.range(of: separator) == nil { return }
                guard data.count < 32_768 else { return }
            }
            guard let boundary = data.range(of: separator) else { return }
            let headerText = String(decoding: data[..<boundary.lowerBound], as: UTF8.self)
            let lines = headerText.components(separatedBy: "\r\n")
            let first = lines.first?.split(separator: " ") ?? []
            guard first.count >= 2 else { return }
            let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
                guard let split = line.firstIndex(of: ":") else { return nil }
                return (String(line[..<split]).lowercased(), line[line.index(after: split)...].trimmingCharacters(in: .whitespaces))
            }, uniquingKeysWith: { _, latest in latest })
            var body = Data(data[boundary.upperBound...])
            let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
            while body.count < bodyLength {
                let chunk = try await connection.receiveChunk(maximumLength: bodyLength - body.count)
                if let bytes = chunk.data { body.append(bytes) }
                if chunk.isComplete && body.count < bodyLength { return }
            }
            let request = Request(method: String(first[0]), target: String(first[1]),
                                  host: headers["host"] ?? "", body: String(decoding: body.prefix(bodyLength), as: UTF8.self))
            requests.append(request)
            let payload = try JSONSerialization.data(withJSONObject: [
                "machine": marker, "method": request.method, "host": request.host, "body": request.body
            ])
            try await connection.sendAll(Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8) + payload)
            try await connection.finishSending()
        } catch {
            // WebKit may open and abandon speculative connections.
        }
    }
}
