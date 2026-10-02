import Darwin
import Foundation

enum TransportError: Error, CustomStringConvertible {
    case sys(String, Int32)
    case socks(String)
    case closed
    case badAddress(String)

    var description: String {
        switch self {
        case .sys(let what, let e): return "\(what): \(String(cString: strerror(e)))"
        case .socks(let m): return "socks5: \(m)"
        case .closed: return "connection closed by peer"
        case .badAddress(let a): return "bad address \(a)"
        }
    }
}

/// A blocking stream socket. Reads come from one thread; writes are serialized by a lock.
final class StreamSocket: @unchecked Sendable {
    let fd: Int32
    let kind: String
    private let writeLock = NSLock()

    private init(fd: Int32, kind: String) {
        self.fd = fd
        self.kind = kind
    }

    deinit { Darwin.close(fd) }

    func shutdown() { Darwin.shutdown(fd, SHUT_RDWR) }

    /// Direct TCP with TCP_NODELAY.
    static func tcp(host: String, port: UInt16) throws -> StreamSocket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else { throw TransportError.badAddress("\(host):\(port) (\(rc))") }
        defer { freeaddrinfo(first) }
        var lastErr: Int32 = 0
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd >= 0 {
                if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                    var one: Int32 = 1
                    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    return StreamSocket(fd: fd, kind: "tcp")
                }
                lastErr = errno
                Darwin.close(fd)
            }
            cur = ai.pointee.ai_next
        }
        throw TransportError.sys("connect \(host):\(port)", lastErr)
    }

    /// Accepts one TCP connection on 127.0.0.1:port (loopback test host only).
    static func acceptOne(port: UInt16) throws -> StreamSocket {
        let lfd = socket(AF_INET, SOCK_STREAM, 0)
        guard lfd >= 0 else { throw TransportError.sys("socket", errno) }
        defer { Darwin.close(lfd) }
        var one: Int32 = 1
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, listen(lfd, 1) == 0 else { throw TransportError.sys("bind/listen 127.0.0.1:\(port)", errno) }
        let fd = accept(lfd, nil, nil)
        guard fd >= 0 else { throw TransportError.sys("accept", errno) }
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return StreamSocket(fd: fd, kind: "tcp-accepted")
    }

    /// SOCKS5 CONNECT (no auth) over a Unix stream socket, e.g. the userspace WireGuard hub.
    static func socksUnix(path: String, host: String, port: UInt16) throws -> StreamSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.sys("socket(AF_UNIX)", errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < cap else {
            Darwin.close(fd)
            throw TransportError.badAddress(path)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw TransportError.sys("connect unix \(path)", e)
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let s = StreamSocket(fd: fd, kind: "socks5-unix")
        try s.socksHandshake(host: host, port: port)
        return s
    }

    private func socksHandshake(host: String, port: UInt16) throws {
        try writeAll([0x05, 0x01, 0x00])
        let greet = try readExact(2)
        guard greet == [0x05, 0x00] else { throw TransportError.socks("greeting reply \(greet)") }
        var req: [UInt8] = [0x05, 0x01, 0x00]
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            req.append(0x01)
            withUnsafeBytes(of: &v4.s_addr) { req.append(contentsOf: $0) }
        } else {
            let name = Array(host.utf8)
            guard name.count < 256 else { throw TransportError.badAddress(host) }
            req.append(0x03)
            req.append(UInt8(name.count))
            req.append(contentsOf: name)
        }
        req.append(UInt8(port >> 8))
        req.append(UInt8(port & 0xff))
        try writeAll(req)
        let head = try readExact(4)
        guard head[0] == 0x05, head[1] == 0x00 else { throw TransportError.socks("connect reply code \(head[1])") }
        switch head[3] {
        case 0x01: _ = try readExact(4 + 2)
        case 0x04: _ = try readExact(16 + 2)
        case 0x03:
            let n = try readExact(1)
            _ = try readExact(Int(n[0]) + 2)
        default: throw TransportError.socks("reply address type \(head[3])")
        }
    }

    func readExact(_ n: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        try out.withUnsafeMutableBytes { try readExact(into: $0) }
        return out
    }

    func readExact(into buf: UnsafeMutableRawBufferPointer) throws {
        guard let base = buf.baseAddress else { return }
        var got = 0
        while got < buf.count {
            let r = Darwin.read(fd, base + got, buf.count - got)
            if r > 0 {
                got += r
            } else if r == 0 {
                throw TransportError.closed
            } else if errno != EINTR {
                throw TransportError.sys("read", errno)
            }
        }
    }

    func writeAll(_ bytes: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let w = Darwin.write(fd, base + sent, raw.count - sent)
                if w > 0 {
                    sent += w
                } else if w < 0, errno != EINTR {
                    throw TransportError.sys("write", errno)
                }
            }
        }
    }
}

/// Parses "HOST:PORT" (IPv6 as "[addr]:port").
func splitHostPort(_ s: String) throws -> (String, UInt16) {
    if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
        let host = String(s[s.index(after: s.startIndex)..<close])
        let rest = s[s.index(after: close)...]
        guard rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) else { throw TransportError.badAddress(s) }
        return (host, p)
    }
    guard let colon = s.lastIndex(of: ":"), let p = UInt16(s[s.index(after: colon)...]) else {
        throw TransportError.badAddress(s)
    }
    return (String(s[..<colon]), p)
}
