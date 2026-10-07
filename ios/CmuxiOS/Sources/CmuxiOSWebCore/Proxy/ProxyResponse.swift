import Foundation

/// Minimal HTTP answers the proxy gives itself (no page reaches the tunnel).
struct ProxyResponse {
    let status: String
    let body: String

    static let badRequest = ProxyResponse(status: "400 Bad Request", body: "Bad request")
    static let forbidden = ProxyResponse(status: "403 Forbidden", body: "This tunnel belongs to another browser.")

    static func badGateway(_ reason: String) -> ProxyResponse {
        ProxyResponse(status: "502 Bad Gateway", body: reason)
    }

    var encoded: Data {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bytes.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + bytes
    }
}
