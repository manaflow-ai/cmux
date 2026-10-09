import CmuxiOSFeatureKit
import Foundation

/// A tunnel stream that plays an HTTP server: once a full request head was
/// written it answers `200 ssh:<request line>` and ends.
actor CannedHTTPStream: TunnelStream {
    private var written = Data()
    private var answered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var closed = false

    var request: String { String(decoding: written, as: UTF8.self) }

    func read() async throws -> Data? {
        if answered { return nil }
        while written.range(of: Data("\r\n\r\n".utf8)) == nil, !closed {
            await withCheckedContinuation { waiter = $0 }
        }
        guard !closed else { return nil }
        answered = true
        let line = request.components(separatedBy: "\r\n").first ?? ""
        let body = Data("ssh:\(line)".utf8)
        return Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    }

    func write(_ data: Data) async throws {
        written.append(data)
        waiter?.resume()
        waiter = nil
    }

    func finishWriting() async {}

    func close() async {
        closed = true
        waiter?.resume()
        waiter = nil
    }
}

/// Records every direct-tcpip open and hands out canned HTTP streams.
actor FakeSSHOpener: SSHDirectTCPIPOpener {
    private(set) var opened: [(host: String, port: Int)] = []
    private(set) var streams: [CannedHTTPStream] = []

    func openDirectTCPIP(host: String, port: Int) async throws -> any TunnelStream {
        opened.append((host, port))
        let stream = CannedHTTPStream()
        streams.append(stream)
        return stream
    }

    func close() async {}
}

/// Counts dials; every dial fails as the Mac would for an unlisted port.
actor CountingDialer: TunnelDialer {
    private(set) var dials = 0

    func dial(port: UInt16) async throws -> any TunnelStream {
        dials += 1
        throw TunnelDialError.refused(code: "tunnel.port_not_allowed", retryable: false)
    }
}

/// Byte-for-byte backend used by the generic SOCKS route test. It records the
/// requested exit and echoes writes so the test exercises authentication,
/// backend adaptation and the bounded relay together.
actor EchoTunnelDialer: TunnelDialer {
    private(set) var opened: [(String, UInt16)] = []

    func dial(port: UInt16) async throws -> any TunnelStream {
        opened.append(("app.localhost", port))
        return EchoTunnelStream()
    }
}

private actor EchoTunnelStream: TunnelStream {
    private var queue: [Data?] = []
    private var waiter: CheckedContinuation<Data?, any Error>?

    func read() async throws -> Data? {
        if !queue.isEmpty { return queue.removeFirst() }
        return await withCheckedContinuation { continuation in waiter = continuation }
    }

    func write(_ data: Data) async throws {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            queue.append(data)
        }
    }

    func finishWriting() async {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        } else {
            queue.append(nil)
        }
    }

    func close() async {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
        queue.removeAll()
    }
}
