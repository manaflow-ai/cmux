public import Foundation

/// The head of the first HTTP/1.x request on a proxied connection: enough
/// to check the route token and rewrite `Host`, never the body.
public struct ProxyRequestHead: Hashable, Sendable {
    public static let maxBytes = 64 * 1024
    static let terminator = Data("\r\n\r\n".utf8)

    public var requestLine: String
    public var headers: [(name: String, value: String)]

    public static func == (lhs: ProxyRequestHead, rhs: ProxyRequestHead) -> Bool {
        lhs.requestLine == rhs.requestLine && lhs.headers.map(\.name) == rhs.headers.map(\.name)
            && lhs.headers.map(\.value) == rhs.headers.map(\.value)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(requestLine)
        for header in headers {
            hasher.combine(header.name)
            hasher.combine(header.value)
        }
    }

    /// Splits `buffer` into a head and the bytes after it, or nil while the
    /// head is incomplete. Throws when it is not an HTTP/1.x request head.
    public static func split(_ buffer: Data) throws(ProxyHeadError) -> (ProxyRequestHead, Data)? {
        guard let end = buffer.range(of: terminator) else {
            if buffer.count >= maxBytes { throw .tooLarge }
            if let first = buffer.first, !(0x41...0x5A).contains(first) { throw .notHTTP }
            return nil
        }
        guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .isoLatin1) else { throw .notHTTP }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[0].allSatisfy({ $0.isUppercase }) else { throw .notHTTP }
        var headers: [(String, String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw .notHTTP }
            headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        return (ProxyRequestHead(requestLine: requestLine, headers: headers), Data(buffer[end.upperBound...]))
    }

    public func values(_ name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// The value of cookie `name` from the `Cookie` headers.
    public func cookie(_ name: String) -> String? {
        for header in values("Cookie") {
            for pair in header.split(separator: ";") {
                let item = pair.trimmingCharacters(in: .whitespaces)
                if item.hasPrefix(name + "=") { return String(item.dropFirst(name.count + 1)) }
            }
        }
        return nil
    }

    public var isUpgrade: Bool { !values("Upgrade").isEmpty }

    /// The head to send on: cookie `strippingCookie` removed, `Host` replaced
    /// when `host` is set, and `Connection: close` when `closeAfter` (unless
    /// the request upgrades, which must keep its own `Connection`).
    public func forwarded(strippingCookie: String, host: String?, closeAfter: Bool) -> Data {
        var out: [String] = [requestLine]
        for (name, value) in headers {
            if name.caseInsensitiveCompare("Cookie") == .orderedSame {
                let kept = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.hasPrefix(strippingCookie + "=") && !$0.isEmpty }
                if !kept.isEmpty { out.append("\(name): \(kept.joined(separator: "; "))") }
            } else if name.caseInsensitiveCompare("Host") == .orderedSame, let host {
                out.append("\(name): \(host)")
            } else if closeAfter, !isUpgrade, name.caseInsensitiveCompare("Connection") == .orderedSame {
                continue
            } else {
                out.append("\(name): \(value)")
            }
        }
        if closeAfter, !isUpgrade { out.append("Connection: close") }
        return Data((out.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}
