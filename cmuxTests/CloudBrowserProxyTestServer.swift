import CmuxCloud
import CryptoKit
import Foundation
import Network

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Authenticated loopback CONNECT/WebSocket peer shared by browser integration tests.
/// Network callbacks enter the main actor before recording or accepting a peer.
@MainActor
final class CloudBrowserProxyTestServer {
    struct Request: Sendable {
        let method: String
        let target: String
        let host: String
        let body: String
    }

    let address: String
    let marker: String
    private let servicePort: Int
    private let pageHTML: String?
    private let styles: CloudLinkFirstValue<Bool>?
    private let securePort: UInt16?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cmux.tests.cloud-browser-connect")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var capturedRequests: [Request] = []
    private var capturedTargets: [String] = []
    private var stopped = false
    private(set) var port: UInt16 = 0
    var requests: [Request] { capturedRequests }
    var authorizedTargets: [String] { capturedTargets }
    private var capturedBridgeRequests: [String] = []
    var bridgeRequests: [String] { capturedBridgeRequests }
    var endpoint: CloudBrowserProxyEndpoint {
        CloudBrowserProxyEndpoint(host: "127.0.0.1", port: port, username: marker, password: "fixture-\(marker)", websocketToken: "ws-token")
    }

    init(address: String, marker: String, styles: CloudLinkFirstValue<Bool>? = nil, securePort: UInt16? = nil, servicePort: Int = 8000, pageHTML: String? = nil) throws {
        self.address = address
        self.marker = marker
        self.servicePort = servicePort
        self.pageHTML = pageHTML
        self.styles = styles
        self.securePort = securePort
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
        guard let bound = await CloudBrowserProxyTestDeadline.value(ready), bound != 0 else {
            stop()
            throw NSError(domain: "CloudBrowserProxyTestServer", code: 1)
        }
        port = bound
    }

    func stop() {
        stopped = true
        let active = Array(connections.values)
        connections.removeAll()
        listener.cancel()
        for connection in active { connection.cancel() }
    }

    private func serve(_ connection: NWConnection) async {
        // A malformed client or an unused WebKit preconnect cannot leave this fixture parked.
        let timeout = Task {
            do {
                try await Task.sleep(for: .seconds(15))
                connection.cancel()
            } catch {}
        }
        defer {
            timeout.cancel()
            connection.cancel()
            connections.removeValue(forKey: ObjectIdentifier(connection))
        }
        do {
            try await connection.startAndWaitUntilReady(queue: queue)
            let first = try await connection.receiveExactly(1)
            var buffered = Data(first)
            if first[0] == UInt8(ascii: "G") {
                let bridge = try await readRequest(connection, buffered: &buffered)
                capturedBridgeRequests.append(bridge.target + " | " + (bridge.headers["sec-websocket-protocol"] ?? ""))
                guard bridge.target.hasPrefix("/__cmux_ws__/") else { return }
                guard bridge.headers["sec-websocket-protocol"]?.contains("cmux-proxy-ws-token") == true,
                      let key = bridge.headers["sec-websocket-key"] else { return }
                let acceptInput = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
                let accept = Data(Insecure.SHA1.hash(data: acceptInput)).base64EncodedString()
                try await connection.sendAll(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Protocol: cmux-proxy-ws-token\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
                try await Task.sleep(for: .seconds(5))
                return
            }
            let connect = try await readRequest(connection, buffered: &buffered)
            let expected = "Basic " + Data("\(marker):fixture-\(marker)".utf8).base64EncodedString()
            guard connect.headers["proxy-authorization"] == expected else {
                try await connection.sendAll(Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"cmux-test\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                try await connection.finishSending()
                return
            }
            guard connect.method == "CONNECT" else {
                try await connection.sendAll(Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                try await connection.finishSending()
                return
            }
            capturedTargets.append(connect.target)
            try await connection.sendAll(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            if connect.target.hasSuffix(":\(port)") {
                let bridge = try await readRequest(connection, buffered: &buffered)
                capturedBridgeRequests.append(bridge.target + " | " + (bridge.headers["sec-websocket-protocol"] ?? ""))
                guard bridge.target.hasPrefix("/__cmux_ws__/"),
                      bridge.headers["sec-websocket-protocol"]?.contains("cmux-proxy-ws-token") == true,
                      let key = bridge.headers["sec-websocket-key"] else { return }
                let acceptInput = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
                let accept = Data(Insecure.SHA1.hash(data: acceptInput)).base64EncodedString()
                try await connection.sendAll(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Protocol: cmux-proxy-ws-token\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
                try await Task.sleep(for: .seconds(5))
                return
            }
            if connect.target == "\(address):8443", let securePort {
                let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: securePort)!, using: .tcp)
                defer { upstream.cancel() }
                try await upstream.startAndWaitUntilReady(queue: queue)
                if !buffered.isEmpty { try await upstream.sendAll(buffered) }
                await CloudPortForwardRelay.relay(connection, upstream)
                return
            }
            guard connect.target == "\(address):\(servicePort)" else { return }
            var request = try await readRequest(connection, buffered: &buffered)
            if request.method == "OPTIONS" {
                try await connection.sendAll(Data("HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET,POST,OPTIONS\r\nAccess-Control-Allow-Headers: content-type\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n".utf8))
                request = try await readRequest(connection, buffered: &buffered)
            }
            let record = Request(method: request.method, target: request.target, host: request.headers["host"] ?? "", body: request.body)
            capturedRequests.append(record)
            let data: Data
            let contentType: String
            if request.target == "/delayed.css", let styles {
                guard await styles.result == true else { return }
                contentType = "text/css"
                data = Data("body { background: rgb(18, 20, 24); color: white; }".utf8)
            } else if request.target == "/unstyled" {
                contentType = "text/html"
                data = Data("<!doctype html><html><body>Unstyled page</body></html>".utf8)
            } else if styles != nil {
                contentType = "text/html"
                data = Data("<!doctype html><html><head><link rel='stylesheet' href='/delayed.css'></head><body>Ordinary website</body></html>".utf8)
            } else if request.target == "/asset.js" {
                contentType = "application/javascript"
                data = Data("window.cloudAsset = '\(marker)-asset';".utf8)
            } else if request.target == "/echo" || request.target.hasPrefix("/echo?") {
                contentType = "application/json"
                data = try JSONSerialization.data(withJSONObject: ["machine": marker, "host": record.host, "body": record.body])
            } else if let pageHTML {
                contentType = "text/html; charset=utf-8"
                data = Data(pageHTML.utf8)
            } else {
                contentType = "text/html; charset=utf-8"
                data = Data("<!doctype html><html><head><script src='/asset.js'></script><script>window.cloudWebSocketState='connecting';window.cloudWebSocket=new WebSocket('ws://'+location.host+'/_next/hmr?id=fixture');window.cloudWebSocket.onopen=()=>window.cloudWebSocketState='open';window.cloudWebSocket.onerror=(e)=>{window.cloudWebSocketState='error';window.cloudWebSocketError=String(e)};</script></head><body data-machine='\(marker)'>\(marker)</body></html>".utf8)
            }
            try await connection.sendAll(Data("HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET,POST,OPTIONS\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8) + data)
            try await connection.finishSending()
        } catch {
            // A discarded WebKit preconnect is normal. Required requests are verified by
            // navigation, page content, and the recorded HTTP requests in the test itself.
        }
    }

    private struct ParsedRequest {
        let method: String
        let target: String
        let headers: [String: String]
        let body: String
    }

    private func readRequest(_ connection: NWConnection, buffered: inout Data) async throws -> ParsedRequest {
        let separator = Data("\r\n\r\n".utf8)
        while buffered.range(of: separator) == nil {
            guard buffered.count < 32_768 else { throw NSError(domain: "CloudBrowserProxyTestServer", code: 2) }
            let chunk = try await connection.receiveChunk(maximumLength: 16_384)
            if let bytes = chunk.data { buffered.append(bytes) }
            if chunk.isComplete && buffered.range(of: separator) == nil { throw NWConnection.StreamError.endedEarly }
        }
        guard let boundary = buffered.range(of: separator) else { throw NWConnection.StreamError.endedEarly }
        let text = String(decoding: buffered[..<boundary.lowerBound], as: UTF8.self)
        buffered.removeSubrange(..<boundary.upperBound)
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3 else { throw NSError(domain: "CloudBrowserProxyTestServer", code: 3) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let count = Int(headers["content-length"] ?? "0") ?? 0
        guard count >= 0, count <= 65_536 else { throw NSError(domain: "CloudBrowserProxyTestServer", code: 4) }
        while buffered.count < count {
            let chunk = try await connection.receiveChunk(maximumLength: 65_536)
            if let bytes = chunk.data { buffered.append(bytes) }
            if chunk.isComplete && buffered.count < count { throw NWConnection.StreamError.endedEarly }
        }
        let body = String(decoding: buffered.prefix(count), as: UTF8.self)
        buffered.removeFirst(count)
        return ParsedRequest(method: String(first[0]), target: String(first[1]), headers: headers, body: body)
    }
}
